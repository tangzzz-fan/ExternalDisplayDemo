import UIKit

extension UIWindowScene {

    /// 手机端 app 所在的那块 scene（`windowApplication` role）。
    ///
    /// 两处要用它：`MockExternalDisplay` 往它上面挂替身窗口，`DemoFlow` 对它发转屏请求。
    /// 判据必须是 **role**，不能取"第一个 windowScene" —— 外接屏 scene 也在
    /// `connectedScenes` 里，抓错了就会对一块不可交互的屏发 `requestGeometryUpdate`，
    /// 而它什么都不会发生（静默失败）。
    static var main: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication }
    }
}
