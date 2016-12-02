// Copyright 2016 Cisco Systems Inc
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.


import Foundation


/// An authentication strategy that uses Spark's OAuth2 mechanism to provide access tokens
public class OAuthStrategy : AuthenticationStrategy {
    private let clientAccount: ClientAccount
    private let scope: String
    private let redirectUri: String
    private let storage: OAuthStorage
    private let oauthClient: OAuthClient
    private let oauthLauncher: OAuthLauncher
    
    /// Returns true if the user has already been authorized
    public var authorized: Bool {
        if let authenticationInfo = storage.authenticationInfo {
            return authenticationInfo.refreshTokenExpirationDate > Date()
        } else {
            return false
        }
    }
    
    init(clientAccount: ClientAccount, scope: String, redirectUri: String,
         storage: OAuthStorage = OAuthKeychainStorage(),
         oauthClient: OAuthClient = OAuthClient(),
         oauthLauncher: OAuthLauncher = OAuthLauncher()) {
        self.clientAccount = clientAccount
        self.scope = scope
        self.redirectUri = redirectUri
        self.storage = storage
        self.oauthClient = oauthClient
        self.oauthLauncher = oauthLauncher
    }
    
    ///
    public func authorize(parentViewController: UIViewController, completionHandler: ((Bool) -> Void)? = nil) {
        let url = createAuthCodeRequestURL()
        oauthLauncher.launchOAuthViewController(parentViewController: parentViewController, authorizationUrl: url, redirectUri: redirectUri) { oauthCode in
            if let oauthCode = oauthCode {
                self.oauthClient.fetchAccessTokenFromOAuthCode(oauthCode, self.clientAccount, redirectUri: self.redirectUri) { response in
                    switch response.result {
                    case .success(let result):
                        self.storage.authenticationInfo = OAuthStrategy.authenticationInfoFrom(accessTokenObject: result)
                    case .failure(let error):
                        Logger.error("Failure retrieving the access token from the oauth code", error: error)
                    }
                    completionHandler?(self.authorized)
                }
            } else {
                completionHandler?(false)
            }
        }
    }
    
    private func createAuthCodeRequestURL() -> URL {
        return URL(string: "https://api.ciscospark.com/v1/authorize?response_type=code"
            + "&client_id=" + clientAccount.clientId.encodeQueryParamString
            + "&redirect_uri=" + redirectUri.encodeQueryParamString
            + "&scope=" + scope.encodeQueryParamString
            + "&state=iossdkstate"
        )!
    }
    
    private static func authenticationInfoFrom(accessTokenObject: AccessToken) -> OAuthAuthenticationInfo? {
        if let accessToken = accessTokenObject.accessTokenString,
            let accessTokenExpiration = accessTokenObject.accessTokenExpiration,
            let refreshToken = accessTokenObject.refreshTokenString,
            let refreshTokenExpiration = accessTokenObject.refreshTokenExpiration {
            let accessTokenExpirationDate = Date(timeInterval: accessTokenExpiration, since: accessTokenObject.accessTokenCreationDate)
            let refreshTokenExpirationDate = Date(timeInterval: refreshTokenExpiration, since: accessTokenObject.accessTokenCreationDate)
            return OAuthAuthenticationInfo(accessToken: accessToken,
                                           accessTokenExpirationDate: accessTokenExpirationDate,
                                           refreshToken: refreshToken,
                                           refreshTokenExpirationDate: refreshTokenExpirationDate)
        }
        return nil
    }
    
    public func deauthorize() {
        storage.authenticationInfo = nil
    }
    
    public func accessToken(completionHandler: @escaping (String?) -> Void) {
        guard authorized, let authenticationInfo = storage.authenticationInfo else {
            completionHandler(nil)
            return
        }
        let buffer: TimeInterval = 15 * 60
        if authenticationInfo.accessTokenExpirationDate > Date(timeIntervalSinceNow: buffer) {
            completionHandler(authenticationInfo.accessToken)
        } else {
            oauthClient.refreshOAuthAccessTokenFromRefreshToken(authenticationInfo.refreshToken, clientAccount) { response in
                switch response.result {
                case .success(let accessTokenObject):
                    if let authInfo = OAuthStrategy.authenticationInfoFrom(accessTokenObject: accessTokenObject) {
                        self.storage.authenticationInfo = authInfo
                    }
                case .failure(let error):
                    self.deauthorize()
                    Logger.error("Failed to refresh token", error: error)
                    PhoneNotificationCenter.sharedInstance.notifyRefreshAccessTokenFailed()
                }
                completionHandler(self.storage.authenticationInfo?.accessToken)
            }
        }
    }
}
