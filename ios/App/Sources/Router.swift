import Observation
import SwiftUI

/// Screens pushed over the tabs (SPEC.md 6.2). Onboarding and the change of words are
/// full-screen flows; the approval card is a sheet.
enum Route: Equatable, Hashable {
    case machineDetail(String)
    case lostMachine(String)
    case pair(fromLink: Bool)
    case answers
    case places
    case devices
    case about
    case licences
    case showWords
    case deleteRelay
    case erase
    case leave
    case report(String)
    case delayed(String)
    case sensitive(String)
    case activity(machine: String?)
    case inventory(machine: String?)
}

enum Tab: Int, Hashable {
    case machines, activity, inventory, settings
}

/// The route stack and the UI-only state shared by the screens.
@MainActor
@Observable
final class Router {
    var stack: [Route] = []
    var tab: Tab = .machines
    /// Screens showing words are up: the app switcher cover and the capture checks apply.
    var secure = 0
    /// A line above Welcome after leaving.
    var goodbye = false
    /// "The screenshot doesn't show your words."
    var screenshotNote = false

    var top: Route? { stack.last }

    func push(_ r: Route) { stack.append(r) }
    func pop() { if !stack.isEmpty { stack.removeLast() } }
    func reset() { stack.removeAll() }
}
