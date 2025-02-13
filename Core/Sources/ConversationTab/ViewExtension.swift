import SwiftUI

let BLUE_IN_LIGHT_THEME = Color(red: 98/255, green: 154/255, blue: 248/255)
let BLUE_IN_DARK_THEME = Color(red: 55/255, green: 108/255, blue: 194/255)

struct HoverBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    var isHovered: Bool

    func body(content: Content) -> some View {
        content
            .background(isHovered ? (colorScheme == .dark ? BLUE_IN_DARK_THEME : BLUE_IN_LIGHT_THEME) : Color.clear)
    }
}

struct HoverRadiusBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    var isHovered: Bool
    var cornerRadius: CGFloat = 0

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isHovered ? (colorScheme == .dark ? BLUE_IN_DARK_THEME : BLUE_IN_LIGHT_THEME) : Color.clear)
            )
    }
}

struct HoverForegroundModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    var isHovered: Bool
    var defaultColor: Color

    func body(content: Content) -> some View {
        content.foregroundColor(isHovered ? Color.white : defaultColor)
    }
}

extension View {
    public func hoverBackground(isHovered: Bool) -> some View {
        self.modifier(HoverBackgroundModifier(isHovered: isHovered))
    }

    public func hoverRadiusBackground(isHovered: Bool, cornerRadius: CGFloat) -> some View {
        self.modifier(HoverRadiusBackgroundModifier(isHovered: isHovered, cornerRadius: cornerRadius))
    }

    public func hoverForeground(isHovered: Bool, defaultColor: Color) -> some View {
        self.modifier(HoverForegroundModifier(isHovered: isHovered, defaultColor: defaultColor))
    }

    public func hoverPrimaryForeground(isHovered: Bool) -> some View {
        self.hoverForeground(isHovered: isHovered, defaultColor: .primary)
    }

    public func hoverSecondaryForeground(isHovered: Bool) -> some View {
        self.hoverForeground(isHovered: isHovered, defaultColor: .secondary)
    }
}
