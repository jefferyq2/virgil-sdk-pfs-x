//
//  SecureChat.swift
//  VirgilSDKPFS
//
//  Created by Oleksandr Deundiak on 6/20/17.
//  Copyright © 2017 VirgilSecurity. All rights reserved.
//

import Foundation
import VirgilSDK

@objc(VSPSecureChat) public class SecureChat: NSObject {
    public static let ErrorDomain = "VSPSecureChatErrorDomain"
    
    public let preferences: SecureChatPreferences
    public let client: Client
    public let virgilClient: VSSClient
    
    fileprivate let keyHelper: SecureChatKeyHelper
    fileprivate let cardsHelper: SecureChatCardsHelper
    fileprivate let sessionHelper: SecureChatSessionHelper
    
    fileprivate var identityCard: VSSCard?
    
    public init(preferences: SecureChatPreferences) {
        self.preferences = preferences
        self.client = Client(serviceConfig: self.preferences.serviceConfig)
        self.virgilClient = VSSClient(serviceConfig: self.preferences.virgilServiceConfig)
        
        self.keyHelper = SecureChatKeyHelper(crypto: self.preferences.crypto, keyStorage: self.preferences.keyStorage)
        self.cardsHelper = SecureChatCardsHelper(crypto: self.preferences.crypto, myPrivateKey: self.preferences.myPrivateKey, client: self.client, deviceManager: self.preferences.deviceManager, keyHelper: self.keyHelper)
        self.sessionHelper = SecureChatSessionHelper()
        
        super.init()
    }
}

// MARK: Talk init
extension SecureChat {
    private func initTalk(withCardsSet cardsSet: RecipientCardsSet, completion: @escaping (SecureTalk?, Error?)->()) throws {
        // FIXME: Check for existing session
        // FIXME: Add otc key on new session
        
        guard let identityCard = self.identityCard else {
            completion(nil, NSError(domain: SecureChat.ErrorDomain, code: -1, userInfo: [NSLocalizedDescriptionKey: "Identity card missing. Probably, SecureChat was not initialized."]))
            return
        }
        
        guard let publicKey = self.preferences.crypto.importPublicKey(from: identityCard.publicKeyData) else {
            completion(nil, NSError(domain: SecureChat.ErrorDomain, code: -1, userInfo: [NSLocalizedDescriptionKey: "Error importing public key from identity card."]))
            return
        }
        
        let longTermPublicKeyData = cardsSet.longTermCard.publicKeyData
        let oneTimePublicKeyData = cardsSet.oneTimeCard.publicKeyData
        guard let oneTimePublicKey = self.preferences.crypto.importPublicKey(from: oneTimePublicKeyData),
            let longTermPublicKey = self.preferences.crypto.importPublicKey(from: longTermPublicKeyData) else {
                completion(nil, NSError(domain: SecureChat.ErrorDomain, code: -1, userInfo: [NSLocalizedDescriptionKey: "Error importing eph public keys from cards."]))
                return
        }
        
        let recipientCardId = cardsSet.identityCard.identifier
        
        let ephKeyPair = self.preferences.crypto.generateKeyPair()
        let ephPrivateKey = ephKeyPair.privateKey
        
        let ephKeyName = try self.keyHelper.saveEphPrivateKey(ephPrivateKey, keyName: recipientCardId)
        
        // FIXME: Optional one time key?
        let sessionState = SessionState(creationDate: Date(), ephKeyName: ephKeyName, recipientPublicKey: publicKey, recipientLongTermPublicKey: longTermPublicKey, recipientOneTimePublicKey: oneTimePublicKey)
        try self.sessionHelper.saveSessionState(sessionState, forRecipientCardId: recipientCardId)
        
        let secureTalk = SecureTalk(crypto: self.preferences.crypto, myIdCard: identityCard, myPrivateKey: self.preferences.myPrivateKey, ephPrivateKey: ephPrivateKey, recipientIdCard: cardsSet.identityCard, recipientLtCard: cardsSet.longTermCard, recipientOtCard: cardsSet.oneTimeCard)
        
        completion(secureTalk, nil)
    }
    
    public func initTalk(withRecipientWithIdentity identity: String, completion: @escaping (SecureTalk?, Error?)->()) {
        self.client.getRecipientCardsSet(forIdentities: [identity]) { cardsSets, error in
            guard error == nil else {
                completion(nil, NSError(domain: SecureChat.ErrorDomain, code: -1, userInfo: [NSLocalizedDescriptionKey: "Error obtaining recipient cards set."]))
                return
            }
            
            guard let cardsSets = cardsSets, cardsSets.count > 0 else {
                completion(nil, NSError(domain: SecureChat.ErrorDomain, code: -1, userInfo: [NSLocalizedDescriptionKey: "Error obtaining recipient cards set. Empty set."]))
                return
            }
            
            // FIXME: Multiple sessions?
            let cardsSet = cardsSets[0]
            
            do {
                try self.initTalk(withCardsSet: cardsSet) { secureTalk, error in
                    completion(secureTalk, error)
                }
            }
            catch {
                // FIXME
            }
        }
    }
}

// MARK: Initialization
extension SecureChat {
    // Workaround for Swift bug SR-2444
    public typealias CompletionHandler = (Error?) -> ()
    
    // FIXME: Get all sessions and check status of LT OT keys
    // FIXME: Check status of old keys and remove unneeded keys
    public func initialize(completion: CompletionHandler? = nil) {
        let errorCallback = { (error: Error?) in
            completion?(error)
        }
        
        var identityCard: VSSCard?
        var numberOfMissingCards: Int?
        
        var numberOfCompletedOperations = 0
        let numberOfOperations = 2
        let operationCompletedCallback = {
            numberOfCompletedOperations += 1
            
            if numberOfOperations == numberOfCompletedOperations {
                guard let identityCard = identityCard,
                    let numberOfMissingCards = numberOfMissingCards else {
                        errorCallback(NSError(domain: SecureChat.ErrorDomain, code: -1, userInfo: [NSLocalizedDescriptionKey: "One or more initialization operations failed."]))
                        return
                }

                self.identityCard = identityCard
                if numberOfMissingCards > 0 {
                    //FIXME: Add longtermcard management
                    do {
                        try self.cardsHelper.addCards(forIdentityCard: identityCard, includeLtcCard: true, numberOfOtcCards: numberOfMissingCards) { error in
                            guard error == nil else {
                                errorCallback(error!)
                                return
                            }
                            
                            completion?(nil)
                        }
                    }
                    catch {
                        errorCallback(error)
                    }
                }
                else {
                    completion?(nil)
                }
            }
        }
        
        // Get identity card
        self.virgilClient.getCard(withId: self.preferences.myCardId) { card, error in
            guard error == nil else {
                errorCallback(error)
                return
            }
            
            guard let card = card else {
                // FIXME
                errorCallback(nil)
                return
            }
            
            identityCard = card
            operationCompletedCallback()
        }
        
        // Check ephemeral cards status
        self.client.getCardsStatus(forUserWithCardId: self.preferences.myCardId) { status, error in
            guard error == nil else {
                errorCallback(error)
                return
            }
            
            guard let status = status else {
                // FIXME
                errorCallback(nil)
                return
            }
            
            // Not enough cards, add more
            numberOfMissingCards = max(self.preferences.numberOfActiveOneTimeCards - status.active, 0)
            operationCompletedCallback()
        }
    }
}