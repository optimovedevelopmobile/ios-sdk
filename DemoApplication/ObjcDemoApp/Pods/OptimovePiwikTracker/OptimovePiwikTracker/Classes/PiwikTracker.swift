import Foundation

/// The Piwik Tracker is a Swift framework to send analytics to the Piwik server.
///
/// ## Basic Usage
/// * Configure the shared instance as early as possible in your application lifecyle.
/// * Use the track methods to track your views, events and more.
final public class PiwikTracker: NSObject {
    
    /// Defines if the user opted out of tracking. When set to true, every event
    /// will be discarded immediately. This property is persisted between app launches.
    @objc public var isOptedOut: Bool {
        get {
            return PiwikUserDefaults.standard.optOut
        }
        set {
            PiwikUserDefaults.standard.optOut = newValue
        }
    }
    
    /// Will be used to associate all future events with a given userID. This property
    /// is persisted between app launches.
    public var visitorId: String? {
        get {
            return PiwikUserDefaults.standard.visitorUserId
        }
        set {
            PiwikUserDefaults.standard.visitorUserId = newValue
            visitor = Visitor.current()
        }
    }
    
    fileprivate let dispatcher: Dispatcher
    private var queue: Queue
    private var optimoveQueue: Queue
    internal let siteId: String
    
    internal var dimensions: [CustomDimension] = []
    
    
    /// This logger is used to perform logging of all sorts of piwik related information.
    /// Per default it is a `DefaultLogger` with a `minLevel` of `LogLevel.warning`. You can
    /// set your own Logger with a custom `minLevel` or a complete custom logging mechanism.
    @objc public var logger: Logger = DefaultLogger(minLevel: .warning)
    
    /// The `contentBase` is used to build the url of an Event, if the Event hasn't got a url set.
    /// This autogenerated url will then have the format <contentBase>/<actions>.
    /// Per default the `contentBase` is http://<Application Bundle Name>.
    /// Set the `contentBase` to nil, if you don't want to auto generate a url.
    @objc public var contentBase: URL?
    
    internal static var _sharedInstance: PiwikTracker?
    
    /// Create and Configure a new Tracker
    ///
    /// - Parameters:
    ///   - siteId: The unique site id generated by the server when a new site was created.
    ///   - queue: The queue to use to store all analytics until it is dispatched to the server.
    ///   - dispatcher: The dispatcher to use to transmit all analytics to the server.
    required public init(siteId: String, queue: Queue, dispatcher: Dispatcher) {
        self.siteId = siteId
        self.queue = queue
        self.optimoveQueue = MemoryQueue()
        self.dispatcher = dispatcher
        self.contentBase = URL(string: "http://\(Application.makeCurrentApplication().bundleIdentifier ?? "unknown")")
        super.init()
        startNewSession()
        startDispatchTimer()
    }
    
    /// Create and Configure a new Tracker
    ///
    /// A volatile memory queue will be used to store the analytics data. All not transmitted data will be lost when the application gets terminated.
    /// The URLSessionDispatcher will be used to transmit the data to the server.
    ///
    /// - Parameters:
    ///   - siteId: The unique site id generated by the server when a new site was created.
    ///   - baseURL: The url of the piwik server. This url has to end in `piwik.php`.
    ///   - userAgent: An optional parameter for custom user agent.
    convenience public init(siteId: String, baseURL: URL, userAgent: String? = nil) {
        assert(baseURL.absoluteString.hasSuffix("piwik.php"), "The baseURL is expected to end in piwik.php")
        
        let queue = MemoryQueue()
        let dispatcher = URLSessionDispatcher(baseURL: baseURL, userAgent: userAgent)
        self.init(siteId: siteId, queue: queue, dispatcher: dispatcher)
    }
    
    internal func queue(event: Event) {
        guard !isOptedOut else { return }
        logger.verbose("Queued event: \(event)")
        queue.enqueue(event: event)
        nextEventStartsANewSession = false
    }
    
    // MARK: dispatching
    
    private let numberOfEventsDispatchedAtOnce = 20
    private(set) var isDispatching = false
    
    
    /// Manually start the dispatching process. You might want to call this method in AppDelegates `applicationDidEnterBackground` to transmit all data
    /// whenever the user leaves the application.
    @objc public func dispatch() {
        guard !isDispatching else {
            logger.verbose("PiwikTracker is already dispatching.")
            return
        }
        guard queue.eventCount > 0 else {
            logger.info("No need to dispatch. Dispatch queue is empty.")
            startDispatchTimer()
            return
        }
        logger.info("Start dispatching events")
        isDispatching = true
        dispatchBatch()
    }
    
    
    private func dispatchBatch() {
        queue.first(limit: numberOfEventsDispatchedAtOnce) { events in
            guard events.count > 0 else {
                // there are no more events queued, finish dispatching
                self.isDispatching = false
                self.startDispatchTimer()
                self.logger.info("Finished dispatching events")
                return
            }
            self.dispatcher.send(events: events, success: {
                self.queue.remove(events: events, completion: {
                    self.logger.info("Dispatched batch of \(events.count) events.")
                    DispatchQueue.main.async {
                        self.dispatchBatch()
                    }
                })
            }, failure: { error in
                self.isDispatching = false
                self.startDispatchTimer()
                self.logger.warning("Failed dispatching events with error \(error)")
            })
        }
    }
    
    // MARK: dispatch timer
    
    public var dispatchInterval: TimeInterval = 30.0 {
        didSet {
            startDispatchTimer()
        }
    }
    private var dispatchTimer: Timer?
    
    private func startDispatchTimer() {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync {
                self.startDispatchTimer()
            }
            return
        }
        guard dispatchInterval > 0  else { return } // Discussion: Do we want the possibility to dispatch synchronous? That than would be dispatchInterval = 0
        if let dispatchTimer = dispatchTimer {
            dispatchTimer.invalidate()
            self.dispatchTimer = nil
        }
        self.dispatchTimer = Timer.scheduledTimer(timeInterval: dispatchInterval, target: self, selector: #selector(dispatch), userInfo: nil, repeats: false)
    }
    
    public var visitor = Visitor.current()
    internal var session = Session.current()
    internal var nextEventStartsANewSession = true
    
}

extension PiwikTracker {
    /// Starts a new Session
    ///
    /// Use this function to manually start a new Session. A new Session will be automatically created only on app start.
    /// You can use the AppDelegates `applicationWillEnterForeground` to start a new visit whenever the app enters foreground.
    public func startNewSession() {
        PiwikUserDefaults.standard.previousVisit = PiwikUserDefaults.standard.currentVisit
        PiwikUserDefaults.standard.currentVisit = Date()
        PiwikUserDefaults.standard.totalNumberOfVisits += 1
        self.session = Session.current()
    }
}

// shared instance
extension PiwikTracker {
    
    /// Returns the shared tracker. Will return nil if the tracker was not properly confured before.
    @objc public static var shared: PiwikTracker? {
        get { return _sharedInstance }
    }
    
    /// Configures the shared instance.
    ///
    /// A volatile memory queue will be used to store the analytics data. All not transmitted data will be lost when the application gets terminated.
    /// The URLSessionDispatcher will be used to transmit the data to the server.
    ///
    /// - Parameters:
    ///   - siteId: The unique site id generated by the server when a new site was created.
    ///   - baseURL: The url of the piwik server. This url has to end in `piwik.php`.
    ///   - userAgent: An optional parameter for custom user agent.
    @objc public class func configureSharedInstance(withSiteID siteID: String, baseURL: URL, userAgent: String? = nil) {
        let queue = MemoryQueue()
        let dispatcher = URLSessionDispatcher(baseURL: baseURL, userAgent: userAgent)
        self._sharedInstance = PiwikTracker.init(siteId: siteID, queue: queue, dispatcher: dispatcher)
    }
    
    /// Configures the shared instance.
    ///
    /// - Parameters:
    /// - Parameters:
    ///   - siteId: The unique site id generated by the server when a new site was created.
    ///   - queue: The queue to use to store all analytics until it is dispatched to the server.
    ///   - dispatcher: The dispatcher to use to transmit all analytics to the server.
    public class func configureSharedInstance(withSiteID siteID: String, queue: Queue = MemoryQueue(), dispatcher: Dispatcher) {
        self._sharedInstance = PiwikTracker(siteId: siteID, queue: queue, dispatcher: dispatcher)
    }
}

extension PiwikTracker {
    
    /// Tracks a custom Event
    ///
    /// - Parameter event: The event that should be tracked.
    public func track(_ event: Event) {
        queue(event: event)
    }
    
    /// Tracks a screenview.
    ///
    /// This method can be used to track hierarchical screen names, e.g. screen/settings/register. Use this to create a hierarchical and logical grouping of screen views in the Piwik web interface.
    ///
    /// - Parameter view: An array of hierarchical screen names.
    /// - Parameter url: The optional url of the page that was viewed.
    /// - Parameter dimensions: An optional array of dimensions, that will be set only in the scope of this view.
    public func track(view: [String], url: URL? = nil, dimensions: [CustomDimension] = []) {
        let event = Event(tracker: self, action: view, url: url, dimensions: dimensions)
        queue(event: event)
    }
    
    /// Tracks an event as described here: https://piwik.org/docs/event-tracking/
    
    /// Track an event as described here: https://piwik.org/docs/event-tracking/
    ///
    /// - Parameters:
    ///   - category: The Category of the Event
    ///   - action: The Action of the Event
    ///   - name: The optional name of the Event
    ///   - value: The optional value of the Event
    ///   - dimensions: An optional array of dimensions, that will be set only in the scope of this event.
    ///   - url: The optional url of the page that was viewed.
    public func track(eventWithCategory category: String, action: String, name: String? = nil, value: Float? = nil, dimensions: [CustomDimension] = [], url: URL? = nil) {
        let event = Event(tracker: self, action: [], url: url, eventCategory: category, eventAction: action, eventName: name, eventValue: value, dimensions: dimensions)
        queue(event: event)
    }
}

extension PiwikTracker {
    /// Set a permanent custom dimension.
    ///
    /// Use this method to set a dimension that will be send with every event. This is best for Custom Dimensions in scope "Visit". A typical example could be any device information or the version of the app the visitor is using.
    ///
    /// For more information on custom dimensions visit https://piwik.org/docs/custom-dimensions/
    ///
    /// - Parameter value: The value you want to set for this dimension.
    /// - Parameter index: The index of the dimension. A dimension with this index must be setup in the piwik backend.
    @available(*, deprecated, message: "use setDimension: instead")
    public func set(value: String, forIndex index: Int) {
        let dimension = CustomDimension(index: index, value: value)
        remove(dimensionAtIndex: dimension.index)
        dimensions.append(dimension)
    }
    
    /// Set a permanent custom dimension.
    ///
    /// Use this method to set a dimension that will be send with every event. This is best for Custom Dimensions in scope "Visit". A typical example could be any device information or the version of the app the visitor is using.
    ///
    /// For more information on custom dimensions visit https://piwik.org/docs/custom-dimensions/
    ///
    /// - Parameter dimension: The Dimension to set
    public func set(dimension: CustomDimension) {
        remove(dimensionAtIndex: dimension.index)
        dimensions.append(dimension)
    }
    
    /// Removes a previously set custom dimension.
    ///
    /// Use this method to remove a dimension that was set using the `set(value: String, forDimension index: Int)` method.
    ///
    /// - Parameter index: The index of the dimension.
    public func remove(dimensionAtIndex index: Int) {
        dimensions = dimensions.filter({ dimension in
            dimension.index != index
        })
    }
}

// Objective-c compatibility extension
extension PiwikTracker {
    
    @objc public func track(view: [String], url: URL? = nil) {
        track(view: view, url: url, dimensions: [])
    }
    
    @objc public func track(eventWithCategory category: String, action: String, name: String? = nil, number: NSNumber? = nil, url: URL? = nil) {
        let value = number == nil ? nil : number!.floatValue
        track(eventWithCategory: category, action: action, name: name, value: value, url: url)
    }
    
    @available(*, deprecated, message: "use trackEventWithCategory:action:name:number:url instead")
    @objc public func track(eventWithCategory category: String, action: String, name: String? = nil, number: NSNumber? = nil) {
        track(eventWithCategory: category, action: action, name: name, number: number, url: nil)
    }
}

//MARK: - Optimove extenssion
extension PiwikTracker
{
    
    public func dispathNow(completion:@escaping(Bool)->Void)
    {
        if isDispatching
        {
            completion(false)
        }
        else
        {
            optimoveDispatch(completion:completion)
        }
    }
    
    func optimoveDispatch(completion:@escaping(Bool) -> Void)
    {
        guard optimoveQueue.eventCount > 0 else {
            logger.info("No need to dispatch. Dispatch queue is empty.")
            startDispatchTimer()
            return
        }
        logger.info("Start dispatching events")
        isDispatching = true
        dispatchBatch {success in
            completion(success)
        }
    }
    public func notificationTrack(eventWithCategory category: String, action: String, name: String? = nil, number: NSNumber? = nil, url: URL? = nil) {
        let value = number == nil ? nil : number!.floatValue
        notificationTrack(eventWithCategory: category, action: action, name: name, value: value, url: url)
    }
    
    public func notificationTrack(eventWithCategory category: String, action: String, name: String? = nil, value: Float? = nil, dimensions: [CustomDimension] = [], url: URL? = nil) {
        let event = Event(tracker: self, action: [], url: url, eventCategory: category, eventAction: action, eventName: name, eventValue: value, dimensions: dimensions)
        optimoveQueue(event: event)
    }
    
    internal func optimoveQueue(event: Event) {
        guard !isOptedOut else { return }
        logger.verbose("Queued event: \(event)")
        optimoveQueue.enqueue(event: event)
    }
    
    public func criticalTrack(eventWithCategory category: String, action: String, name: String? = nil, value: Float? = nil, dimensions: [CustomDimension] = [], url: URL? = nil,completion:@escaping(Bool) -> Void) {
        if isDispatching
        {
            completion(false)
        }
        isDispatching = true
        let event = Event(tracker: self, action: [], url: url, eventCategory: category, eventAction: action, eventName: name, eventValue: value, dimensions: dimensions)
        self.dispatcher.send(event: event, success: {
            self.isDispatching = false
            self.startDispatchTimer()
            completion(true)
        }) { _ in
            self.isDispatching = false
            self.startDispatchTimer()
            completion(false)
        }
    }
    
    private func dispatchBatch(completion:@escaping(Bool) -> Void) {
        optimoveQueue.first(limit: numberOfEventsDispatchedAtOnce) { events in
            guard events.count > 0 else {
                // there are no more events queued, finish dispatching
                self.isDispatching = false
                self.startDispatchTimer()
                self.logger.info("Finished dispatching events")
                completion(true)
                return
            }
            self.dispatcher.send(events: events, success: {
                self.optimoveQueue.remove(events: events, completion: {
                    self.logger.info("Dispatched batch of \(events.count) events.")
                    DispatchQueue.main.async {
                        self.dispatchBatch(completion:completion)
                    }
                })
            }, failure: { error in
                self.isDispatching = false
                self.startDispatchTimer()
                self.logger.warning("Failed dispatching events with error \(error)")
                completion(false)
            })
        }
    }
}

//MARK: - Optimove Dispatch persistance
public protocol PiwikDispatcherDelegate
{
    func didFinish(json:Data)
    func didFail(json:Data)
}


