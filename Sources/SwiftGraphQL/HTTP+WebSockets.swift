import Foundation
import Network

import os.log

extension OSLog {
    private static var subsystem = Bundle.main.bundleIdentifier!
    static let subscription = OSLog(subsystem: subsystem, category: "subscription")
}

public typealias URLSessionGraphQLSocket = GraphQLSocket<URLSessionWebSocketTask>
public typealias NWConnectionGraphQLSocket = GraphQLSocket<NWConnection>

public protocol GraphQLEnabledSocket {
    associatedtype InitParamaters
    associatedtype New where New == Self
    static func create(with params: InitParamaters, errorHandler: @escaping (GraphQLSocket<New>.SubscribeError) -> Void) -> New
    
    /// - parameter errorHandler: A closure that receives an Error that indicates an error encountered while sending.
    func send(message: Data, errorHandler: @escaping (Error) -> Void)
    /// - returns: On true, will stop listening to the socket
    func receiveMessages(_ handler: @escaping (Result<Data, Error>) -> Bool)
}

final class SinglePingQueueToken {
    var cancelled = false
}

/// https://github.com/enisdenjo/graphql-ws/blob/master/PROTOCOL.md
public class GraphQLSocket<S: GraphQLEnabledSocket> {
    
    typealias Message = GraphQLSocketMessage
    
    enum SocketState {
        case notRunning, started, running
    }
    
    private let restartQueue = DispatchQueue(label: "GraphQLSocketRestartQueue")
    private var socket: S?
    private var initParams: S.InitParamaters
    private var autoConnect: Bool
    private var pingInterval: TimeInterval?
    private var lastConnectionParams = AnyCodable([String: String]())
    private var state: SocketState = .notRunning {
        didSet { startQueue() }
    }
    private var queue: [(GraphQLSocket) -> Void] = []
    private var subscriptions: [String: (GraphQLSocketMessage) -> Void] = [:]
    
    private var decoder = JSONDecoder()
    private var encoder = JSONEncoder()
    
    // Every successful ping should be matched by a successful pong
    private var pingPongMatches: Int = 0
    
    // we should never have more than one ping queue token
    var pingQueueToken: SinglePingQueueToken?
    
    public init(_ params: S.InitParamaters, autoConnect: Bool = false, pingInterval: TimeInterval? = nil) {
        self.initParams = params
        self.autoConnect = autoConnect
        self.pingInterval = pingInterval
    }
    
    public enum StartError: Error {
        case alreadyStarted
        case failedToEncodeConnectionParams(error: Error)
        case connectionInit(error: Error)
    }
    
    /// Starts a socket without connectionParams.
    public func start(errorHandler: @escaping (SubscribeError) -> Void) {
        start(connectionParams: [String: String](), errorHandler: errorHandler)
    }
    
    /// Starts a socket.
    public func start<P>(connectionParams: P, errorHandler: @escaping (SubscribeError) -> Void) {
        guard state == .notRunning else {
            return errorHandler(.startError(.alreadyStarted))
        }
        
        do {
            lastConnectionParams = AnyCodable(connectionParams)
            let message = Message.connectionInit(connectionParams)
            let messageData = try encoder.encode(message)
//            os_log("Start Connection: %{public}@",
//                   log: OSLog.subscription,
//                   type: .debug,
//                   (String(data: messageData, encoding: .utf8) ?? "Invalid .utf8")
//            )
            state = .started
            socket = S.create(with: initParams, errorHandler: errorHandler)
            socket?.send(message: messageData, errorHandler: { [weak self] in
                self?.restart(errorHandler: errorHandler)
                errorHandler(.startError(.connectionInit(error: $0)))
            })
            socket?.receiveMessages { [weak self] (message) -> Bool in
                switch message {
                case .success(let data):
//                    os_log("Received Data: %{public}@",
//                           log: OSLog.subscription,
//                           type: .debug, (String(data: data, encoding: .utf8) ?? "Invalid .utf8")
//                    )
                    guard var message = try? JSONDecoder().decode(Message.self, from: data) else {
                        os_log("Invalid JSON Payload", log: OSLog.subscription, type: .debug)
                        return false
                    }
                    switch message.type {
                    case .connection_ack:
                        self?.state = .running
                        // If we have a time interval, set up a ping thread
                        if let pingInterval = self?.pingInterval {
                            // cancel the old token
                            self?.pingQueueToken?.cancelled = true
                            let token = SinglePingQueueToken()
                            self?.pingQueueToken = token
                            self?.detachedPingQueue(interval: pingInterval, errorHandler: { error in
                                errorHandler(.pingFailed(error))
                            }, pingHandler: { [weak self] in
                                guard let self = self else { return }
                                self.pingPongMatches += 1
                                // If we pinged 5 times without a pong, try to restart
                                if self.pingPongMatches > 5 {
                                    self.pingPongMatches = 0
                                    self.restart(errorHandler: errorHandler)
                                }
                            }, token: token)
                        }
                    case .ka:
                        self?.state = .running
                    case .next, .error, .complete, .data:
                        guard let id = message.id else { return false }
                        message.originalData = data
                        self?.subscriptions[id]?(message)
                    case .connection_terminate, .connection_error:
                        self?.restart(errorHandler: errorHandler)
                        return true
                    case .pong:
                        self?.pingPongMatches -= 1
                        self?.state = .running
                    case .subscribe, .connection_init, .ping:
                        _ = "The server will never send these messages"
                    }
                    
                case .failure(let failure):
                    os_log("Received Error: %{public}@", log: OSLog.subscription, type: .debug, failure.localizedDescription)
                    // Retry the start in a couple of seconds.
                    // Should we send this error to the start errorHandler?
                    // This could happen during the entire lifetime of the socket so
                    // it's not really a start error
                    //errorHandler(.startError(.connectionInit(error: failure)))
                    self?.restart(errorHandler: errorHandler)
                    return true
                }
                return false
            }
        } catch {
            return errorHandler(.startError(.failedToEncodeConnectionParams(error: error)))
        }
    }
    
    private func detachedPingQueue(
        interval: TimeInterval,
        errorHandler: @escaping (Error) -> Void,
        pingHandler: @escaping () -> Void,
        token: SinglePingQueueToken
    ) {
        // if there is a new token, leave here, so there's always only one ping queue
        guard !token.cancelled else {
            return
        }
        if state == .notRunning {
            // Try again while we're restarting
            restartQueue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.detachedPingQueue(interval: interval, errorHandler: errorHandler, pingHandler: pingHandler, token: token)
            }
            return
        }
        restartQueue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self = self else {
                return
            }
            do {
                let message = Message.ping()
                let messageData = try self.encoder.encode(message)
                self.socket?.send(message: messageData, errorHandler: errorHandler)
                pingHandler()
                os_log(
                    "Ping",
                    log: OSLog.subscription,
                    type: .debug
                )
            } catch let error {
                errorHandler(error)
            }
            // Schedule the next
            self.detachedPingQueue(interval: interval, errorHandler: errorHandler, pingHandler: pingHandler, token: token)
        }
    }
    
    public enum SubscribeError: Error {
        case notStartedAndNoAutoConnect
        case failedToEncodeSelection(Error)
        /// Check if the server returned the correct format
        case failedToDecodeSelection(Error)
        case failedToDecodeGraphQLErrors(Error)
        case errors([GraphQLError])
        case subscribeFailed(Error)
        case pingFailed(Error)
        case complete
        case startError(StartError)
    }
    
    public func subscribe<Type, TypeLock: GraphQLOperation & Decodable>(
        to selection: Selection<Type, TypeLock?>,
        operationName: String? = nil,
        eventHandler: @escaping (Result<GraphQLResult<Type, TypeLock>, SubscribeError>) -> Void
    ) -> SocketCancellable {
        let id = UUID().uuidString
        let cancellable = SocketCancellable { [weak self] in
            self?.complete(id: id)
        }
        
        #if DEBUG
        #if targetEnvironment(simulator)
        let payload = selection.buildPayload(operationName: operationName)

        // Write the query. We also need the id, so we encode it into the variables
        try? payload.query.write(toFile: "/tmp/query_\(id).graphql", atomically: true, encoding: .utf8)
        // Write the variables
        var copiedVariables = payload.variables
        copiedVariables["gql-subscription-id"] = AnyCodable(stringLiteral: id)
        if let variables = try? encoder.encode(copiedVariables) {
            try? variables.write(to: URL(fileURLWithPath: "/tmp/query_variables_\(id).json"))
        }
        #endif
        #endif
        
        switch state {
        case .notRunning:
            if autoConnect {
                queue += [{ [weak cancellable] in
                    cancellable?.add($0.subscribe(to: selection, operationName: operationName, eventHandler: eventHandler))
                }]
                start(connectionParams: lastConnectionParams, errorHandler: {
                    eventHandler(.failure($0))
                })
            } else {
                os_log("GraphQLSocket: Call start first or enable autoConnect",
                       log: OSLog.subscription,
                       type: .debug
                )
                eventHandler(.failure(.notStartedAndNoAutoConnect))
            }
        case .started:
            os_log("GraphQLSocket: Still waiting for connection_ack from the server so subscribe is queued",
                   log: OSLog.subscription,
                   type: .debug
            )
            queue += [{ [weak cancellable] in
                cancellable?.add($0.subscribe(to: selection, operationName: operationName, eventHandler: eventHandler))
            }]
        case .running:
            do {
                let payload = selection.buildPayload(operationName: operationName)
                let message = Message.subscribe(payload, id: id)
                let messageData = try encoder.encode(message)
//                os_log("Outgoing Data: %{public}@",
//                       log: OSLog.subscription,
//                       type: .debug, (String(data: messageData, encoding: .utf8) ?? "Invalid .utf8")
//                )
                socket?.send(message: messageData, errorHandler: {
                    eventHandler(.failure(.subscribeFailed($0)))
                })
                subscriptions[id] = { message in
                    switch message.type {
                    case .next, .data:
                        do {
                            if let originalData = message.originalData {

#if DEBUG
#if targetEnvironment(simulator)
                                // write the response out. A given subscription can have multiple responses.
                                let debugTime = DispatchTime.now().uptimeNanoseconds
                                let url = URL(fileURLWithPath: "/tmp/subscription_response_\(id)_\(debugTime).json")
                                try? originalData.write(to: url)
#endif
#endif
                            }
                            let result = try GraphQLResult(webSocketMessage: message, with: selection)
                            eventHandler(.success(result))
                        } catch {
                            eventHandler(.failure(.failedToDecodeSelection(error)))
                        }
                    case .error, .connection_error:
                        do {
                            let result: [GraphQLError] = try message.decodePayload()
                            eventHandler(.failure(.errors(result)))
                        } catch {
                            eventHandler(.failure(.failedToDecodeGraphQLErrors(error)))
                        }
                    case .connection_terminate:
                        eventHandler(.failure(.complete))
                    case .complete:
                        eventHandler(.failure(.complete))
                    case .ka, .pong: ()
                    case .connection_init, .connection_ack, .subscribe, .ping:
                        os_log("Invalid subscription case %{public}@", log: OSLog.subscription, type: .debug, message.type.rawValue)
                        assertionFailure()
                    }
                    
                }
            } catch {
                eventHandler(.failure(.failedToEncodeSelection(error)))
            }
        }
        
        return cancellable
    }
    
    /// Closes the current socket, you can then call start to open a new socket
    public func stop() {
        state = .notRunning
        socket = nil
    }
    
    /// try to restart the socket after a brief delay
    public func restart(errorHandler: @escaping (SubscribeError) -> Void) {
        self.state = .notRunning
        let params = lastConnectionParams
        restartQueue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.start(connectionParams: params, errorHandler: errorHandler)
        }
    }
    
    private func complete(id: String) {
        subscriptions[id] = nil
        let message = Message.complete(id: id)
        let messageData = try! encoder.encode(message)
        socket?.send(message: messageData, errorHandler: { _ in })
    }
    
    /// Starts the queue if the websocket is running
    private func startQueue() {
        guard state == .running else { return }
        queue.forEach { $0(self) }
        queue = []
    }
}

/// MARK: Messages

public struct GraphQLSocketMessage: Codable {
    public enum MessageType: String, Codable {
        case connection_init
        case connection_ack
        case subscribe
        case next
        case error
        case complete
        case ka
        case connection_error
        case connection_terminate
        case data
        case ping
        case pong
    }
    
    public var originalData: Data?
    
    public var type: MessageType
    public var id: String?
    /// Used for retreiving payload after decoding incomming message
    private var container: KeyedDecodingContainer<CodingKeys>?
    /// Used for payload on outgoing message
    private var addedPayload: AnyCodable?
    
    private enum CodingKeys: CodingKey {
        case type
        case id
        case payload
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(addedPayload, forKey: .payload)
    }
    
    public enum DecodingPayloadError: Swift.Error {
        /// This can happen when the Message struct was not initialised through Decodable
        case missingContainer
    }

    public func decodePayload<IncommingPayload: Decodable>(ofType type: IncommingPayload.Type = IncommingPayload.self) throws -> IncommingPayload {
        if let container = container {
            return try container.decode(IncommingPayload.self, forKey: .payload)
        } else {
            throw DecodingPayloadError.missingContainer
        }
    }
}

// decoder init in extension so swift still generates a memberwise init
extension GraphQLSocketMessage {
    public init(from decoder: Decoder) throws {
        self.container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container!.decode(MessageType.self, forKey: .type)
        self.id = try container!.decodeIfPresent(String.self, forKey: .id)
    }
}

/// MARK: Outgoing messages

extension GraphQLSocketMessage {
    public static func connectionInit<P>(_ connectionParams: P) -> GraphQLSocketMessage {
        return .init(type: .connection_init, id: nil, addedPayload: AnyCodable(connectionParams))
    }
    
    public static func ping() -> GraphQLSocketMessage {
        return .init(type: .ping, id: nil, addedPayload: AnyCodable([:]))
    }
    
    /// Requests an operation specified in the message `payload`. This message provides a
    /// unique ID field to connect published messages to the operation requested by this message.
    public static func subscribe<P>(_ payload: P, id: String) -> GraphQLSocketMessage {
        return .init(type: .subscribe, id: id, addedPayload: AnyCodable(payload))
    }
    
    /// Indicates that the client has stopped listening and wants to complete the subscription.
    /// No further events, relevant to the original subscription, should be sent through. Even if the client
    /// completed a single result operation before it resolved, the result should not be sent through once it does.
    public static func complete(id: String) -> GraphQLSocketMessage {
        return .init(type: .complete, id: id)
    }
}

public struct GraphQLQueryPayload: Encodable {
    public var query: String
    public var variables: [String: AnyCodable]
    public var operationName: String?
    
    internal init<Type, TypeLock, Operation>(
        selection: Selection<Type, TypeLock>,
        operationType: Operation.Type,
        operationName: String?
    ) where Operation: GraphQLOperation {
        self.query = selection.selection.serialize(for: Operation.operation, operationName: operationName)
        
        self.variables = [:]
        for argument in selection.selection.arguments {
            variables[argument.hash] = argument.value
        }
        
        self.operationName = operationName
    }
}



/// Automatically calls `cancel()` when deinitialized.
final public class SocketCancellable: Hashable {
    public init(_ cancel: @escaping () -> Void) {
        self._cancel = cancel
    }
    
    private var _cancel: () -> Void
    
    func add(_ cancellable: SocketCancellable) {
        let copy = _cancel
        _cancel = {
            cancellable.cancel()
            copy()
        }
    }
    
    /// Cancel the activity.
    final public func cancel() {
        _cancel()
    }
    
    deinit {
        _cancel()
    }
    
    public static func == (lhs: SocketCancellable, rhs: SocketCancellable) -> Bool {
        lhs === rhs
    }
    
    final public func hash(into hasher: inout Hasher) {
        hasher.combine("\(self)")
    }
    
    final public func store<C>(in collection: inout C) where C : RangeReplaceableCollection, C.Element == SocketCancellable {
        collection.append(self)
    }
    
    final public func store(in set: inout Set<SocketCancellable>) {
        set.insert(self)
    }
}

#if canImport(Combine)
import Combine

extension SocketCancellable {
    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    public func toAnyCancellable() -> AnyCancellable {
        AnyCancellable(_cancel)
    }
}
#endif

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension NWConnection: GraphQLEnabledSocket {
    public struct InitParamaters {
        let url: URL
        let headers: HttpHeaders
        let queue: DispatchQueue
        
        public init(url: URL, headers: HttpHeaders, queue: DispatchQueue) {
            self.url = url
            self.headers = headers
            self.queue = queue
        }
    }
    
    public typealias New = NWConnection
    
    public class func create(with params: InitParamaters, errorHandler: @escaping (GraphQLSocket<NWConnection>.SubscribeError) -> Void) -> NWConnection {
        
        let endpoint = NWEndpoint.url(params.url)
        let parameters: NWParameters = params.url.scheme == "wss" ? .tls : .tcp
        let websocketOptions = NWProtocolWebSocket.Options()
        websocketOptions.autoReplyPing = true
        websocketOptions.maximumMessageSize = 1024 * 1024 * 100
        
        var headers: [(String, String)] = []
        for header in params.headers {
            headers.append((header.key, header.value))
        }
        headers.append(("Sec-WebSocket-Protocol", "graphql-transport-ws"))
        headers.append(("Content-Type", "application/json"))
        websocketOptions.setAdditionalHeaders(headers)
        
        parameters.defaultProtocolStack.applicationProtocols.insert(
            websocketOptions,
            at: 0
        )
        let connection = NWConnection(to: endpoint, using: parameters)
        
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                os_log("Connection Ready", log: OSLog.subscription, type: .debug)
            case .failed(let error):
                os_log("Connection Failed: %{public}@",
                       log: OSLog.subscription,
                       type: .error,
                       error.localizedDescription
                )
                errorHandler(.subscribeFailed(error))
            case .waiting(let error):
                os_log("Waiting Error: %{public}@",
                       log: OSLog.subscription,
                       type: .error,
                       error.localizedDescription
                )
                errorHandler(.subscribeFailed(error))
                
            case .setup:
//                os_log("Setup State Update", log: OSLog.subscription, type: .debug)
                ()
            case .preparing:
//                os_log("Preparing State Update", log: OSLog.subscription, type: .debug)
                ()
            case .cancelled:
                os_log("Cancelled State Update", log: OSLog.subscription, type: .debug)
            @unknown default:
                os_log("Unknown State Update", log: OSLog.subscription, type: .debug)
            }
        }
        
        connection.start(queue: params.queue)
        return connection
    }
    
    public func send(message: Data, errorHandler: @escaping (Error) -> Void) {
        self.send(content: message, completion: .contentProcessed({ error in
            guard let error = error else { return }
            errorHandler(error)
        }))
    }
    
    public func receiveMessages(_ handler: @escaping (Result<Data, Error>) -> Bool) {
        // Create an event handler.
        func receiveNext(on socket: NWConnection?) {
            socket?.receiveMessage(completion: { completeContent, contentContext, isComplete, error in
                let cancel: Bool
                switch (completeContent, error) {
                case (let content?, _):
                    cancel = handler(.success(content))
                case (_, let error?):
                    cancel = handler(.failure(error))
                default:
                    cancel = false
                }
                guard cancel == false else { return }
                receiveNext(on: socket)
            })
        }
        
        receiveNext(on: self)
    }
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension URLSessionWebSocketTask: GraphQLEnabledSocket {
    public struct InitParamaters {
        let url: URL
        let headers: HttpHeaders
        let session: URLSession
        
        public init(url: URL, headers: HttpHeaders, session: URLSession = URLSession.shared) {
            self.url = url
            self.headers = headers
            self.session = session
        }
    }
    
    public typealias New = URLSessionWebSocketTask
    public class func create(with params: InitParamaters, errorHandler: @escaping (GraphQLSocket<URLSessionWebSocketTask>.SubscribeError) -> Void) -> URLSessionWebSocketTask {
        var request = URLRequest(url: params.url)
        for header in params.headers {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }
        request.setValue("graphql-transport-ws", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "GET"
        let task = params.session.webSocketTask(with: request)
        task.resume()
        return task
    }
    
    public func send(message: Data, errorHandler: @escaping (Error) -> Void) {
//        os_log(
//            "Send data: %{private}@",
//            log: OSLog.subscription,
//            type: .debug,
//            String(data: message, encoding: .utf8) ?? "Invalid Encoding"
//        )
        self.send(.data(message), completionHandler: {
            if let error = $0 {
                errorHandler(error)
            }
        })
    }
    
    public func receiveMessages(_ handler: @escaping (Result<Data, Error>) -> Bool) {
        // Create an event handler.
        func receiveNext(on socket: URLSessionWebSocketTask?) {
            socket?.receive { [weak socket] result in
                let cancel = handler(result.map(\.data))
                guard cancel == false else {
                    socket?.cancel(with: .goingAway, reason: nil)
                    return
                }
                receiveNext(on: socket)
            }
        }
        
        receiveNext(on: self)
    }
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension URLSessionWebSocketTask.Message {
    var data: Data {
        switch self {
        case let .data(data):
            return data
        case let .string(string):
            return string.data(using: .utf8) ?? Data()
        @unknown default:
            return Data()
        }
    }
}
