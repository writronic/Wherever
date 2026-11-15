import AppKit

struct ModePictureLayout {
    struct Motion {
        enum Kind { case fade, grow, rise }

        let kind: Kind
        let start: CFTimeInterval
        let end: CFTimeInterval
    }

    struct Shape {
        let name: String
        let frame: CGRect
        let radius: CGFloat
        let fill: NSColor
        var outlined = false
        var outlinedInHighContrast = false
        var motion: Motion?
    }

    static let size = CGSize(width: 180, height: 114)
    static let radius: CGFloat = 4
    static let border: CGFloat = 1
    static let growFrom = 0.4
    static let riseFrom = -4.0

    static let loop: CFTimeInterval = 5.0
    static let fadeStart: CFTimeInterval = 4.6

    let shapes: [Shape]

    static let simple = ModePictureLayout(shapes: [
        titleBar,
        field("searchField", x: 8, y: 18, width: 164, height: 12, radius: 3, grows: 0.30, to: 1.10),
        selectedRow(y: 38, rises: 1.50),
        bar("row2", y: 55, width: 96, rises: 1.70),
        bar("row3", y: 69, width: 72, rises: 1.90),
        bar("row4", y: 83, width: 110, rises: 2.10),
        bar("row5", y: 97, width: 84, rises: 2.30)
    ])

    static let normal = ModePictureLayout(shapes: [
        titleBar,
        field("field1", x: 40, y: 16, width: 132, height: 9, radius: 2, grows: 0.30, to: 0.70),
        field("field2", x: 40, y: 28, width: 132, height: 9, radius: 2, grows: 0.50, to: 0.90),
        field("field3", x: 40, y: 40, width: 132, height: 9, radius: 2, grows: 0.70, to: 1.10),
        pill("pill1", x: 8, width: 26, fades: 1.20),
        pill("pill2", x: 38, width: 30, fades: 1.30),
        pill("pill3", x: 72, width: 24, fades: 1.40),
        selectedRow(y: 66, rises: 1.90),
        bar("row2", y: 83, width: 100, rises: 2.10),
        bar("row3", y: 97, width: 76, rises: 2.30)
    ])

    private static let titleBar = Shape(name: "titleBar", frame: CGRect(x: 0, y: 0, width: 180, height: 12), radius: 0, fill: .separatorColor)

    private static func field(_ name: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, radius: CGFloat, grows start: CFTimeInterval, to end: CFTimeInterval) -> Shape {
        Shape(name: name, frame: CGRect(x: x, y: y, width: width, height: height), radius: radius, fill: .textBackgroundColor, outlined: true, outlinedInHighContrast: true, motion: Motion(kind: .grow, start: start, end: end))
    }

    private static func pill(_ name: String, x: CGFloat, width: CGFloat, fades start: CFTimeInterval) -> Shape {
        Shape(name: name, frame: CGRect(x: x, y: 53, width: width, height: 8), radius: 4, fill: .separatorColor, outlinedInHighContrast: true, motion: Motion(kind: .fade, start: start, end: start + 0.25))
    }

    private static func selectedRow(y: CGFloat, rises start: CFTimeInterval) -> Shape {
        Shape(name: "row1", frame: CGRect(x: 4, y: y, width: 172, height: 10), radius: 3, fill: .controlAccentColor, motion: Motion(kind: .rise, start: start, end: start + 0.30))
    }

    private static func bar(_ name: String, y: CGFloat, width: CGFloat, rises start: CFTimeInterval) -> Shape {
        Shape(name: name, frame: CGRect(x: 8, y: y, width: width, height: 4), radius: 2, fill: .secondaryLabelColor, motion: Motion(kind: .rise, start: start, end: start + 0.30))
    }
}
