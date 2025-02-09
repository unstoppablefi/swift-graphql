//import Combine
import Foundation
import Gzip

/*
 SwiftGraphQL has no client as it needs no state. Developers
 should take care of caching and other implementation themselves.
 */

// MARK: - Send

/// Sends a query request to the server.
///
/// - parameter endpoint: Server endpoint URL.
/// - parameter operationName: The name of the GraphQL query.
/// - parameter headers: A dictionary of key-value header pairs.
/// - parameter onEvent: Closure that is called each subscription event.
/// - parameter method: Method to use. (Default to POST).
/// - parameter session: URLSession to use. (Default to .shared).
///
@discardableResult
public func send<Type, TypeLock>(
    _ selection: Selection<Type, TypeLock?>,
    to endpoint: String,
    operationName: String? = nil,
    headers: HttpHeaders = [:],
    method: HttpMethod = .post,
    session: URLSession = .shared,
    compressRequest: Bool = false,
    onComplete completionHandler: @escaping (Response<Type, TypeLock>) -> Void
) -> URLSessionDataTask? where TypeLock: GraphQLHttpOperation & Decodable {
    send(
        selection: selection,
        operationName: operationName,
        endpoint: endpoint,
        headers: headers,
        method: method,
        session: session,
        compressRequest: compressRequest,
        completionHandler: completionHandler
    )
}

/// Sends a query request to the server.
///
/// - Note: This is a shortcut function for when you are expecting the result.
///         The only difference between this one and the other one is that you may select
///         on non-nullable TypeLock instead of a nullable one.
///
/// - parameter endpoint: Server endpoint URL.
/// - parameter operationName: The name of the GraphQL query.
/// - parameter headers: A dictionary of key-value header pairs.
/// - parameter onEvent: Closure that is called each subscription event.
/// - parameter method: Method to use. (Default to POST).
/// - parameter session: URLSession to use. (Default to .shared).
///
@discardableResult
public func send<Type, TypeLock>(
    _ selection: Selection<Type, TypeLock>,
    to endpoint: String,
    operationName: String? = nil,
    headers: HttpHeaders = [:],
    method: HttpMethod = .post,
    session: URLSession = .shared,
    compressRequest: Bool = false,
    onComplete completionHandler: @escaping (Response<Type, TypeLock>) -> Void
) -> URLSessionDataTask? where TypeLock: GraphQLHttpOperation & Decodable {
    send(
        selection: selection.nonNullOrFail,
        operationName: operationName,
        endpoint: endpoint,
        headers: headers,
        method: method,
        session: session,
        compressRequest: compressRequest,
        completionHandler: completionHandler
    )
}


/// Sends a query to the server using given parameters.
private func send<Type, TypeLock>(
    selection: Selection<Type, TypeLock?>,
    operationName: String?,
    endpoint: String,
    headers: HttpHeaders,
    method: HttpMethod,
    session: URLSession,
    compressRequest: Bool = false,
    completionHandler: @escaping (Response<Type, TypeLock>) -> Void
) -> URLSessionDataTask? where TypeLock: GraphQLOperation & Decodable {
    // Validate that we got a valid url.
    guard let url = URL(string: endpoint) else {
        completionHandler(.failure(.badURL))
        return nil
    }
    
    let debugTime = DispatchTime.now().uptimeNanoseconds
    
    // Construct a GraphQL request.
    let request = createGraphQLRequest(
        selection: selection,
        operationName: operationName,
        url: url,
        headers: headers,
        method: method,
        compressRequest: compressRequest,
        debugTime: debugTime
    )
    
    // Create a completion handler.
    func onComplete(data: Data?, response: URLResponse?, error: Error?) {
        
        // Save the response or the error, depending on what's available
        #if DEBUG
        #if targetEnvironment(simulator)
        let fallback = "\(String(describing: response))".data(using: .utf8) ?? "{'error': 'Could not serialize response'}".data(using: .utf8)!
        let responeData: Data
        if let data = data {
            responeData = data
        } else if let error = error {
            responeData = "{'error': '\(error.localizedDescription)'}".data(using: .utf8)
                ?? fallback
        } else {
            responeData = fallback
        }
        let url = URL(fileURLWithPath: "/tmp/query_response_\(debugTime).json")
        try? responeData.write(to: url)
        #endif
        #endif
        
        /* Process the response. */
        // Check for HTTP errors.
        if let error = error {
            return completionHandler(.failure(.network(error)))
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return completionHandler(.failure(.badstatus(nil)))
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            return completionHandler(.failure(.badstatus(httpResponse.statusCode)))
        }

        // Try to serialize the response.
        if let data = data {
            do {
                let result = try GraphQLResult(data, with: selection)
                return completionHandler(.success(result))
            } catch let error as HttpError {
                return completionHandler(.failure(error))
            } catch let error {
                return completionHandler(.failure(.decodingError(error, extensions: nil)))
            }
        }

        return completionHandler(.failure(.badpayload))
    }

    // Construct a session data task.
    let dataTask = session.dataTask(with: request, completionHandler: onComplete)
    
    dataTask.resume()
    return dataTask
    
}


// MARK: - Request type aliaii

/// Represents an error of the actual request.
public enum HttpError: Error {
    case badURL
    case timeout
    case network(Error)
    case badpayload
    case badstatus(Int?)
    case cancelled
    case decodingError(Error, extensions: [String: AnyCodable]?)
    case graphQLErrors([GraphQLError], extensions: [String: AnyCodable]?)
}

extension HttpError: Equatable {
    public static func == (lhs: SwiftGraphQL.HttpError, rhs: SwiftGraphQL.HttpError) -> Bool {
        // Equals if they are of the same type, different otherwise.
        switch (lhs, rhs) {
        case (.badstatus(let a), .badstatus(let b)): return a == b
        case (.badURL, badURL),
            (.timeout, .timeout),
            (.badpayload, .badpayload),
            (.cancelled, .cancelled),
            (.network, .network),
            (.decodingError, .decodingError),
            (.graphQLErrors, .graphQLErrors):
            return true
        default:
            return false
        }
    }
}


public enum HttpMethod: String, Equatable {
    case get = "GET"
    case post = "POST"
}

/// A return value that might contain a return value as described in GraphQL spec.
public typealias Response<Type, TypeLock> = Result<GraphQLResult<Type, TypeLock>, HttpError>

/// A dictionary of key-value pairs that represent headers and their values.
public typealias HttpHeaders = [String: String]

// MARK: - Utility functions

/*
 Each of the exposed functions has a backing private helper.
 We use `perform` method to send queries and mutations,
 `listen` to listen for subscriptions, and there's an overarching utility
 `request` method that composes a request and send it.
 */

/// Creates a valid URLRequest using given selection.
private func createGraphQLRequest<Type, TypeLock>(
    selection: Selection<Type, TypeLock?>,
    operationName: String?,
    url: URL,
    headers: HttpHeaders,
    method: HttpMethod,
    compressRequest: Bool,
    debugTime: UInt64
) -> URLRequest where TypeLock: GraphQLOperation & Decodable {
    // Construct a request.
    var request = URLRequest(url: url)

    for header in headers {
        request.setValue(header.value, forHTTPHeaderField: header.key)
    }

    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpMethod = method.rawValue

    // Construct HTTP body.
    let encoder = JSONEncoder()
    let payload = selection.buildPayload(operationName: operationName)
    
    #if DEBUG
    #if targetEnvironment(simulator)
    // Write the query
    try? payload.query.write(toFile: "/tmp/query_\(debugTime).graphql", atomically: true, encoding: .utf8)
    // Write the variables
    if let variables = try? encoder.encode(payload.variables) {
        try? variables.write(to: URL(fileURLWithPath: "/tmp/query_variables_\(debugTime).json"))
    }
    #endif
    #endif
    request.httpBody = try? encoder.encode(payload)

    if compressRequest, let gzipped = try? request.httpBody?.gzipped() {
        request.httpBody = gzipped
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
    }

    return request
}

