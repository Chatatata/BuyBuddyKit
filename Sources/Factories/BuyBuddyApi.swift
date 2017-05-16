//
//  BuyBuddyApi.swift
//  BuyBuddyKit
//
//  Created by Furkan on 5/16/17.
//
//

import Foundation
import Alamofire
import ObjectMapper

private let sandBoxPrefix = "sandbox-api";
private let productionPrefix = "api";
private var isSandBox: Bool = false
private func getBaseUrl() -> String{
    return "https://" + (isSandBox ? sandBoxPrefix : productionPrefix) + ".buybuddy.co"
}

enum BuyBuddyEndpoint : String {
    case QrHitag = "GET /iot/scan/<hitag_id>"  // GET
    case ScanHitag = "POST /iot/scan_record" // POST
    case GetJwt = "/iam/users/tokens"   // POST
}

protocol BuyBuddyInvalidTokenDelegate{
    func tokenExpired()
}

class BuyBuddyApi {
    
    public static let sharedInstance: BuyBuddyApi = BuyBuddyApi()
    private let buyBuddySessionManager = SessionManager()
    var tokenDelegate: BuyBuddyInvalidTokenDelegate?
    var isAccessTokenSet = false
    
    public static func getBaseUrl() -> String{
        return "https://" + (isSandBox ? sandBoxPrefix : productionPrefix) + ".buybuddy.co"
    }
    
    public func sandBoxMode(isActive: Bool){
        isSandBox = isActive
    }
    public func setAccessToken(_ token: String, invalidTokenDelegate: BuyBuddyInvalidTokenDelegate){
        Utilities.saveToUd(key: "access_token", value: token)
        isAccessTokenSet = true
        
        buyBuddySessionManager.adapter = BuyBuddyJwtAdapter(accessToken: token,
                                                            jwt: BuyBuddyUserJwt.getCurrentJwt(),
                                                            sessionManager: buyBuddySessionManager,
                                                            tokenDelegate: tokenDelegate)
        self.tokenDelegate = invalidTokenDelegate
    }

    public init(){
        if (Utilities.getFromUd(key: "access_token") as? String) == nil {
            //"UYARI 1" Kullanıcıya bir token atanmadan sdk çalışmayacaktır.
            self.isAccessTokenSet = false
        }else{
            self.isAccessTokenSet = true
        }
    }
    
    typealias SuccessHandler<T: Mappable> = (_ result: T, _ operation: HTTPURLResponse?)
        -> Void
    typealias ErrorHandler = (_ error: Error, _ operation: HTTPURLResponse?)
        -> Void
    
    func call<T: Mappable>(endPoint: BuyBuddyEndpoint,
              parameters: [String : Any],
              method: HTTPMethod? = .get,
              success: @escaping (SuccessHandler<T>),
              error: @escaping (ErrorHandler)){
        
        if !isAccessTokenSet {
            //"UYARI 1" Kullanıcıya bir token atanmadan sdk çalışmayacaktır.
            print("Access Token Setlemeniz Gerekiyor")
            return
        }
        
        let endPoint = Endpoint.buildURL(endPoint: endPoint.rawValue, values: parameters as [String : AnyObject])
        
        buyBuddySessionManager.request(endPoint.URL.absoluteString!,
                                       method: endPoint.method,
                                       parameters: endPoint.otherValues,
                                       encoding: JSONEncoding.default)
            .validate()
            .responseJSON { (response) in
            
                if response.error != nil{
                    return error(response.error!, response.response)
                }
                
                switch response.result {
                case .success(let value):
                    let result = Mapper<T>().map(JSON: value as! [String: Any])
                    
                    if result != nil{
                        success(result!, response.response)
                    }else{
                        
                    }
                    break
                case .failure(let err):
                    error(err, response.response)
            }
        }
    }

    func getProductWith(hitagId: String,
                        success: @escaping  (SuccessHandler<ItemData>),
                        error: @escaping (ErrorHandler)){
        
        call(endPoint: BuyBuddyEndpoint.QrHitag, parameters: ["hitag_id" : hitagId], success: success, error: error)
    }
}

class BuyBuddyJwtAdapter: RequestAdapter, RequestRetrier {
    private typealias RefreshCompletion = (_ succeeded: Bool, _ jwt: BuyBuddyUserJwt?) -> Void
    private var jwt: BuyBuddyUserJwt?
    private var accessToken: String?
    private var sessionManager: SessionManager!
    private var tokenDelegate: BuyBuddyInvalidTokenDelegate?
    private let lock = NSLock()
    
    init(accessToken: String!, jwt: BuyBuddyUserJwt?, sessionManager: SessionManager, tokenDelegate: BuyBuddyInvalidTokenDelegate?) {
        self.accessToken = accessToken
        self.jwt = jwt
        self.sessionManager = sessionManager
        
        if jwt == nil {
            refreshJwt(completion: { (bool, jwt) in
                if jwt != nil{
                    Utilities.saveToUd(key: "user_jwt", value: jwt!.toDict())
                }else{
                    tokenDelegate?.tokenExpired()
                }
            })
        }
    }
    
    private var isRefreshing = false
    private var requestsToRetry: [RequestRetryCompletion] = []
    
    func should(_ manager: SessionManager, retry request: Request, with error: Error, completion: @escaping RequestRetryCompletion) {
        lock.lock(); defer { lock.unlock() }
        
        if let response = request.task?.response as? HTTPURLResponse, response.statusCode == 401 {
            requestsToRetry.append(completion)
            
            if !isRefreshing {
                refreshJwt { [weak self] succeeded, jwt in
                    guard let strongSelf = self else { return }
                    
                    strongSelf.lock.lock() ; defer { strongSelf.lock.unlock() }
                    
                    if let jwt = jwt {
                        strongSelf.jwt = jwt
                    }
                    
                    strongSelf.requestsToRetry.forEach { $0(succeeded, 0.0) }
                    strongSelf.requestsToRetry.removeAll()
                }
            }
        } else {
            completion(false, 0.0)
        }
    }
    
    private func refreshJwt(completion: @escaping RefreshCompletion) {
        guard !isRefreshing else { return }
        
        isRefreshing = true
        
        let passphrase_submission: [String: Any] = [
            "passphrase_submission" : ["passkey" : accessToken]
        ]
        
        let urlString = "\(getBaseUrl()) + \(BuyBuddyEndpoint.GetJwt)"
        
        sessionManager.request(urlString, method: .post, parameters: passphrase_submission, encoding: JSONEncoding.default)
            .responseJSON { [weak self] response in
                guard let strongSelf = self else { return }
                
                if response.result.isSuccess{
                    
                    if let userJwt = Mapper<BuyBuddyUserJwt>().map(JSON: response.result.value as! [String: Any])  {
                        BuyBuddyUserJwt.setCurrentJwt(jwt: userJwt)
                        completion(true, userJwt)
                    }else{
                        completion(false, nil)
                    }
                    
                }else{
                    completion(false, nil)
                }
                strongSelf.isRefreshing = false
        }
    }
    
    func adapt(_ urlRequest: URLRequest) throws -> URLRequest {
        var urlRequest = urlRequest
        
        if jwt != nil{
            if let urlString = urlRequest.url?.absoluteString, urlString.hasPrefix(getBaseUrl()) {
                urlRequest.setValue("Bearer " + jwt!.jwt, forHTTPHeaderField: "Authorization")
            }
        }
        
        return urlRequest
    }
}
