import Foundation

private var interposeKey: Character = "_"

struct AssociatedKeys {
    static var interposeObject: UInt8 = 0
}

extension NSObject {
    /// Access an existing Interpose container, if available.
    var interpose: Interpose? {
        get { objc_getAssociatedObject(self, &AssociatedKeys.interposeObject) as? Interpose }
        set { objc_setAssociatedObject(self, &AssociatedKeys.interposeObject, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
}

/// Interpose is a modern library to swizzle elegantly in Swift.
///
/// Methods are hooked via replacing the implementation, instead of the usual exchange.
/// Supports both swizzling classes and individual objects.
final public class Interpose {
    /// Stores swizzle hooks and executes them at once.
    public let `class`: AnyClass
    /// Lists all hooks for the current interpose class object.
    public private(set) var hooks: [AnyHook] = []

    /// If Interposing is object-based, this is set.
    public let object: AnyObject?

    // Checks if a object is posing as a different class
    // via implementing 'class' and returning something else.
    private func checkObjectPosingAsDifferentClass(_ object: AnyObject) -> AnyClass? {
        let perceivedClass: AnyClass = type(of: object)
        let actualClass: AnyClass = object_getClass(object)!
        if actualClass != perceivedClass {
            return actualClass
        }
        return nil
    }

    // This is based on observation, there is no documented way
    private func isKVORuntimeGeneratedClass(_ klass: AnyClass) -> Bool {
        NSStringFromClass(klass).hasPrefix("NSKVO")
    }

    /// Initializes an instance of Interpose for a specific class.
    /// If `builder` is present, `apply()` is automatically called.
    public init(_ `class`: AnyClass, builder: ((Interpose) throws -> Void)? = nil) throws {
        self.class = `class`
        self.object = nil

        // Only apply if a builder is present
        if let builder = builder {
            try apply(builder)
        }
    }

    /// Initialize with a single object to interpose.
    public init(_ object: NSObject, builder: ((Interpose) throws -> Void)? = nil) throws {
        self.object = object
        self.class = type(of: object)

        if let actualClass = checkObjectPosingAsDifferentClass(object) {
            if isKVORuntimeGeneratedClass(actualClass) {
                throw InterposeError.keyValueObservationDetected(object)
            } else {
                throw InterposeError.objectPosingAsDifferentClass(object, actualClass: actualClass)
            }
        }

        // Only apply if a builder is present
        if let builder = builder {
            try apply(builder)
        }

        // Store interpose on object
        object.interpose = self
    }

    deinit {
        hooks.forEach({ $0.cleanup() })
    }
    
    /// Hook an `@objc dynamic` instance method via selector name on the current class.
    @discardableResult public func hook<MethodSignature, HookSignature>(
        _ selName: String,
        methodSignature: MethodSignature.Type = MethodSignature.self,
        hookSignature: HookSignature.Type = HookSignature.self,
        _ implementation:(TypedHook<MethodSignature, HookSignature>) -> HookSignature?) throws -> TypedHook<MethodSignature, HookSignature>  {
        try hook(NSSelectorFromString(selName), methodSignature: methodSignature, hookSignature: hookSignature, implementation)
    }

    /// Hook an `@objc dynamic` instance method via selector  on the current class.
    @discardableResult public func hook<MethodSignature, HookSignature> (
        _ selector: Selector,
        methodSignature: MethodSignature.Type = MethodSignature.self,
        hookSignature: HookSignature.Type = HookSignature.self,
       _ implementation:(TypedHook<MethodSignature, HookSignature>) -> HookSignature?) throws -> TypedHook<MethodSignature, HookSignature> {

        var hook: TypedHook<MethodSignature, HookSignature>
        if let object = self.object {
            hook = try ObjectHook(object: object, selector: selector, implementation: implementation)
        } else {
            hook = try ClassHook(class: `class`, selector: selector, implementation: implementation)
        }
        hooks.append(hook)
        return hook
    }

    /// Apply all stored hooks.
    @discardableResult public func apply(_ hook: ((Interpose) throws -> Void)? = nil) throws -> Interpose {
        try execute(hook) { try $0.apply() }
    }

    /// Revert all stored hooks.
    @discardableResult public func revert(_ hook: ((Interpose) throws -> Void)? = nil) throws -> Interpose {
        try execute(hook, expectedState: .interposed) { try $0.revert() }
    }

    private func execute(_ task: ((Interpose) throws -> Void)? = nil,
                         expectedState: AnyHook.State = .prepared,
                         executor: ((AnyHook) throws -> Void)) throws -> Interpose {
        // Run pre-apply code first
        if let task = task {
            try task(self)
        }
        // Validate all tasks, stop if anything is not valid
        guard hooks.allSatisfy({
            (try? $0.validate(expectedState: expectedState)) != nil
        }) else {
            throw InterposeError.invalidState(expectedState: expectedState)
        }
        // Execute all tasks
        try hooks.forEach(executor)
        return self
    }
}

/// The list of errors while hooking a method.
public enum InterposeError: LocalizedError {
    /// The method couldn't be found. Usually happens for when you use stringified selectors that do not exist.
    case methodNotFound(AnyClass, Selector)

    /// The implementation could not be found. Class must be in a weird state for this to happen.
    case nonExistingImplementation(AnyClass, Selector)

    /// Someone else changed the implementation; reverting removed this implementation.
    /// This is bad, likely someone else also hooked this method. If you are in such a codebase, do not use revert.
    case unexpectedImplementation(AnyClass, Selector, IMP?)

    /// Unable to register subclass for object-based interposing.
    case failedToAllocateClassPair(class: AnyClass, subclassName: String)

    /// Unable to add method  for object-based interposing.
    case unableToAddMethod(AnyClass, Selector)

    /// Object-based hooking does not work if an object is using KVO.
    /// The KVO mechanism also uses subclasses created at runtime but doesn't check for additional overrides.
    /// Adding a hook eventually crashes the KVO management code so we reject hooking altogether in this case.
    case keyValueObservationDetected(AnyObject)

    /// Object is lying about it's actual class metadata.
    /// This usually happens when other swizzling libraries (like Aspects) also interfere with a class.
    /// While this might just work, it's not worth risking a crash, so similar to KVO this case is rejected.
    ///
    /// @note Printing classes in Swift uses the class posing mechanism. Use `NSClassFromString` to get the correct name.
    case objectPosingAsDifferentClass(AnyObject, actualClass: AnyClass)

    /// Can't revert or apply if already done so.
    case invalidState(expectedState: AnyHook.State)
}

extension InterposeError: Equatable {
    // Lazy equating via string compare
    public static func == (lhs: InterposeError, rhs: InterposeError) -> Bool {
        return lhs.errorDescription == rhs.errorDescription
    }

    public var errorDescription: String? {
        switch self {
        case .methodNotFound(let klass, let selector):
            return "Method not found: -[\(klass) \(selector)]"
        case .nonExistingImplementation(let klass, let selector):
            return "Implementation not found: -[\(klass) \(selector)]"
        case .unexpectedImplementation(let klass, let selector, let IMP):
            return "Unexpected Implementation in -[\(klass) \(selector)]: \(String(describing: IMP))"
        case .failedToAllocateClassPair(let klass, let subclassName):
            return "Failed to allocate class pair: \(klass), \(subclassName)"
        case .unableToAddMethod(let klass, let selector):
            return "Unable to add method: -[\(klass) \(selector)]"
        case .keyValueObservationDetected(let obj):
            return "Unable to hook object that uses Key Value Observing: \(obj)"
        case .objectPosingAsDifferentClass(let obj, let actualClass):
            return "Unable to hook object posing as different class. Expected: \(type(of: obj)) Is: \(NSStringFromClass(actualClass))/"
        case .invalidState(let expectedState):
            return "Invalid State. Expected: \(expectedState)"
        }
    }

    @discardableResult func log() -> InterposeError {
        Interpose.log(self.errorDescription!)
        return self
    }
}

// MARK: Logging

extension Interpose {
    /// Logging uses print and is minimal.
    public static var isLoggingEnabled = false

    /// Simple log wrapper for print.
    class func log(_ object: Any) {
        if isLoggingEnabled {
            print("[Interposer] \(object)")
        }
    }
}
