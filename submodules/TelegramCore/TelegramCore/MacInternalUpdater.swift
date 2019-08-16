import TelegramApiMac
import SwiftSignalKitMac
import PostboxMac

public enum InternalUpdaterError {
    case generic
    case xmlLoad
    case archiveLoad
}

public func requestUpdatesXml(account: Account, source: String) -> Signal<Data, InternalUpdaterError> {
    return resolvePeerByName(account: account, name: source)
        |> introduceError(InternalUpdaterError.self)
        |> mapToSignal { peerId -> Signal<Peer?, InternalUpdaterError> in
            return account.postbox.transaction { transaction in
                return peerId != nil ? transaction.getPeer(peerId!) : nil
                } |> introduceError(InternalUpdaterError.self)
        }
        |> mapToSignal { peer in
            if let peer = peer, let inputPeer = apiInputPeer(peer) {
                return account.network.request(Api.functions.messages.getHistory(peer: inputPeer, offsetId: 0, offsetDate: 0, addOffset: 0, limit: 1, maxId: Int32.max, minId: 0, hash: 0))
                    |> retryRequest
                    |> introduceError(InternalUpdaterError.self)
                    |> mapToSignal { result in
                        switch result {
                        case let .channelMessages(_, _, _, apiMessages, apiChats, apiUsers):
                            if let apiMessage = apiMessages.first, let storeMessage = StoreMessage(apiMessage: apiMessage) {
                                
                                var peers: [PeerId: Peer] = [:]
                                for chat in apiChats {
                                    if let groupOrChannel = parseTelegramGroupOrChannel(chat: chat) {
                                        peers[groupOrChannel.id] = groupOrChannel
                                    }
                                }
                                for user in apiUsers {
                                    let telegramUser = TelegramUser(user: user)
                                    peers[telegramUser.id] = telegramUser
                                }
                                
                                if let message = locallyRenderedMessage(message: storeMessage, peers: peers), let media = message.media.first as? TelegramMediaFile {
                                    return Signal { subscriber in
                                        let fetchDispsable = fetchedMediaResource(mediaBox: account.postbox.mediaBox, reference: MediaResourceReference.media(media: AnyMediaReference.message(message: MessageReference(message), media: media), resource: media.resource)).start()
                                        
                                        let dataDisposable = account.postbox.mediaBox.resourceData(media.resource, option: .complete(waitUntilFetchStatus: true)).start(next: { data in
                                            if data.complete {
                                                if let data = try? Data(contentsOf: URL.init(fileURLWithPath: data.path)) {
                                                    subscriber.putNext(data)
                                                    subscriber.putCompletion()
                                                } else {
                                                    subscriber.putError(.xmlLoad)
                                                }
                                            }
                                        })
                                        return ActionDisposable {
                                            fetchDispsable.dispose()
                                            dataDisposable.dispose()
                                        }
                                    }
                                }
                            }
                        default:
                            break
                        }
                        return .fail(.xmlLoad)
                    }
            } else {
                return .fail(.xmlLoad)
            }
    }
}

public enum AppUpdateDownloadResult {
    case started(Int)
    case progress(Int, Int)
    case finished(String)
}

public func downloadAppUpdate(account: Account, source: String, fileName: String) -> Signal<AppUpdateDownloadResult, InternalUpdaterError> {
    return resolvePeerByName(account: account, name: source)
        |> introduceError(InternalUpdaterError.self)
        |> mapToSignal { peerId -> Signal<Peer?, InternalUpdaterError> in
            return account.postbox.transaction { transaction in
                return peerId != nil ? transaction.getPeer(peerId!) : nil
                } |> introduceError(InternalUpdaterError.self)
        }
        |> mapToSignal { peer in
            if let peer = peer, let inputPeer = apiInputPeer(peer) {
                return account.network.request(Api.functions.messages.getHistory(peer: inputPeer, offsetId: 0, offsetDate: 0, addOffset: 0, limit: 10, maxId: Int32.max, minId: 0, hash: 0))
                    |> retryRequest
                    |> introduceError(InternalUpdaterError.self)
                    |> mapToSignal { result in
                        switch result {
                        case let .channelMessages(_, _, _, apiMessages, apiChats, apiUsers):
                            
                            var peers: [PeerId: Peer] = [:]
                            for chat in apiChats {
                                if let groupOrChannel = parseTelegramGroupOrChannel(chat: chat) {
                                    peers[groupOrChannel.id] = groupOrChannel
                                }
                            }
                            for user in apiUsers {
                                let telegramUser = TelegramUser(user: user)
                                peers[telegramUser.id] = telegramUser
                            }
                            
                            let messageAndFile:(Message, TelegramMediaFile)? = apiMessages.compactMap { value in
                                return StoreMessage(apiMessage: value)
                            }.compactMap { value in
                                return locallyRenderedMessage(message: value, peers: peers)
                            }.sorted(by: {
                                $0.id > $1.id
                            }).first(where: { value -> Bool in
                                if let file = value.media.first as? TelegramMediaFile, file.fileName == fileName {
                                    return true
                                } else {
                                    return false
                                }
                            }).map { ($0, $0.media.first as! TelegramMediaFile )}
                            
                            if let (message, media) = messageAndFile {
                                return Signal { subscriber in
                                    
                                    let reference = MediaResourceReference.media(media: .message(message: MessageReference(message), media: media), resource: media.resource)
                                    
                                    let fetchDispsable = fetchedMediaResource(mediaBox: account.postbox.mediaBox, reference: reference).start()
                                    
                                    let statusDisposable = account.postbox.mediaBox.resourceStatus(media.resource).start(next: { status in
                                        switch status {
                                        case let .Fetching(_, progress):
                                            if let size = media.size {
                                                if progress == 0 {
                                                    subscriber.putNext(.started(size))
                                                } else {
                                                    subscriber.putNext(.progress(Int(progress * Float(size)), Int(size)))
                                                }
                                            }
                                        default:
                                            break
                                        }
                                    })
                                    
                                    let dataDisposable = account.postbox.mediaBox.resourceData(media.resource, option: .complete(waitUntilFetchStatus: true)).start(next: { data in
                                        if data.complete {
                                            subscriber.putNext(.finished(data.path))
                                            subscriber.putCompletion()
                                        }
                                    })
                                    return ActionDisposable {
                                        fetchDispsable.dispose()
                                        dataDisposable.dispose()
                                        statusDisposable.dispose()
                                    }
                                }
                            } else {
                                return .fail(.archiveLoad)
                            }
                        default:
                            break
                        }
                        return .fail(.archiveLoad)
                }
            } else {
                return .fail(.archiveLoad)
            }
    }
}
