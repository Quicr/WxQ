class Weak<T: AnyObject> {
    private weak var value: T?
    init(_ value: T) {
        self.value = value
    }
}
