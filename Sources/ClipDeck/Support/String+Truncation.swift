import Foundation

extension String {
    func truncated(to maximumLength: Int) -> String {
        guard maximumLength > 0 else {
            return ""
        }

        guard count > maximumLength else {
            return self
        }

        guard maximumLength > 1 else {
            return String(prefix(maximumLength))
        }

        return String(prefix(maximumLength - 1)) + "…"
    }
}
