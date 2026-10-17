// Path painters for the SF Symbols the profile surfaces show: the 31 avatar
// icons of Marquee/Models/UserProfile.swift:60-92 and the editing glyphs of
// ProfilePickerView.swift. Each takes a 2D context already set up with the
// ink, the line width, and round joins, and a `size` that is the square the
// symbol fills. Filled symbols (`.fill`) fill; the rest stroke.
.pragma library

function circle(context, x, y, radius) {
    context.moveTo(x + radius, y)
    context.arc(x, y, radius, 0, 2 * Math.PI)
}

function star(context, cx, cy, outer, inner, points) {
    for (let index = 0; index < points * 2; ++index) {
        const radius = index % 2 === 0 ? outer : inner
        const angle = -Math.PI / 2 + index * Math.PI / points
        const x = cx + radius * Math.cos(angle)
        const y = cy + radius * Math.sin(angle)
        if (index === 0) context.moveTo(x, y); else context.lineTo(x, y)
    }
    context.closePath()
}

function heart(context, s) {
    context.beginPath()
    context.moveTo(0.50 * s, 0.90 * s)
    context.bezierCurveTo(0.10 * s, 0.62 * s, 0.02 * s, 0.38 * s, 0.18 * s, 0.22 * s)
    context.bezierCurveTo(0.32 * s, 0.10 * s, 0.46 * s, 0.18 * s, 0.50 * s, 0.30 * s)
    context.bezierCurveTo(0.54 * s, 0.18 * s, 0.68 * s, 0.10 * s, 0.82 * s, 0.22 * s)
    context.bezierCurveTo(0.98 * s, 0.38 * s, 0.90 * s, 0.62 * s, 0.50 * s, 0.90 * s)
    context.closePath()
    context.fill()
}

function starFill(context, s) {
    context.beginPath()
    star(context, 0.5 * s, 0.53 * s, 0.47 * s, 0.20 * s, 5)
    context.fill()
}

function moonFill(context, s) {
    context.beginPath()
    context.arc(0.52 * s, 0.50 * s, 0.42 * s, 0.30 * Math.PI, 1.70 * Math.PI, false)
    context.arc(0.68 * s, 0.50 * s, 0.34 * s, 1.62 * Math.PI, 0.38 * Math.PI, true)
    context.closePath()
    context.fill()
}

function sunMaxFill(context, s) {
    context.beginPath()
    circle(context, 0.5 * s, 0.5 * s, 0.20 * s)
    context.fill()
    context.beginPath()
    for (let index = 0; index < 8; ++index) {
        const angle = index * Math.PI / 4
        context.moveTo(0.5 * s + 0.31 * s * Math.cos(angle), 0.5 * s + 0.31 * s * Math.sin(angle))
        context.lineTo(0.5 * s + 0.46 * s * Math.cos(angle), 0.5 * s + 0.46 * s * Math.sin(angle))
    }
    context.stroke()
}

function boltFill(context, s) {
    context.beginPath()
    context.moveTo(0.58 * s, 0.04 * s)
    context.lineTo(0.22 * s, 0.56 * s)
    context.lineTo(0.46 * s, 0.56 * s)
    context.lineTo(0.40 * s, 0.96 * s)
    context.lineTo(0.78 * s, 0.42 * s)
    context.lineTo(0.54 * s, 0.42 * s)
    context.closePath()
    context.fill()
}

function flameFill(context, s) {
    context.beginPath()
    context.moveTo(0.50 * s, 0.04 * s)
    context.bezierCurveTo(0.56 * s, 0.24 * s, 0.82 * s, 0.34 * s, 0.82 * s, 0.62 * s)
    context.bezierCurveTo(0.82 * s, 0.82 * s, 0.68 * s, 0.96 * s, 0.50 * s, 0.96 * s)
    context.bezierCurveTo(0.32 * s, 0.96 * s, 0.18 * s, 0.82 * s, 0.18 * s, 0.62 * s)
    context.bezierCurveTo(0.18 * s, 0.50 * s, 0.26 * s, 0.42 * s, 0.30 * s, 0.34 * s)
    context.bezierCurveTo(0.32 * s, 0.46 * s, 0.40 * s, 0.50 * s, 0.42 * s, 0.44 * s)
    context.bezierCurveTo(0.36 * s, 0.30 * s, 0.44 * s, 0.14 * s, 0.50 * s, 0.04 * s)
    context.closePath()
    context.fill()
}

function leafFill(context, s) {
    context.beginPath()
    context.moveTo(0.88 * s, 0.12 * s)
    context.bezierCurveTo(0.40 * s, 0.10 * s, 0.10 * s, 0.40 * s, 0.16 * s, 0.84 * s)
    context.bezierCurveTo(0.60 * s, 0.90 * s, 0.90 * s, 0.60 * s, 0.88 * s, 0.12 * s)
    context.closePath()
    context.fill()
    context.beginPath()
    context.moveTo(0.20 * s, 0.82 * s)
    context.lineTo(0.72 * s, 0.30 * s)
    context.stroke()
}

function snowflake(context, s) {
    context.beginPath()
    for (let index = 0; index < 6; ++index) {
        const angle = index * Math.PI / 3
        const dx = Math.cos(angle)
        const dy = Math.sin(angle)
        context.moveTo(0.5 * s, 0.5 * s)
        context.lineTo(0.5 * s + 0.44 * s * dx, 0.5 * s + 0.44 * s * dy)
        // Two branches on each arm.
        const bx = 0.5 * s + 0.28 * s * dx
        const by = 0.5 * s + 0.28 * s * dy
        const left = angle + Math.PI / 3
        const right = angle - Math.PI / 3
        context.moveTo(bx, by)
        context.lineTo(bx + 0.12 * s * Math.cos(left), by + 0.12 * s * Math.sin(left))
        context.moveTo(bx, by)
        context.lineTo(bx + 0.12 * s * Math.cos(right), by + 0.12 * s * Math.sin(right))
    }
    context.stroke()
}

function cloudFill(context, s) {
    context.beginPath()
    context.arc(0.32 * s, 0.62 * s, 0.20 * s, 0.5 * Math.PI, 1.5 * Math.PI)
    context.arc(0.48 * s, 0.42 * s, 0.22 * s, 1.0 * Math.PI, 1.9 * Math.PI)
    context.arc(0.70 * s, 0.56 * s, 0.22 * s, 1.35 * Math.PI, 0.5 * Math.PI)
    context.closePath()
    context.fill()
}

function globeAmericasFill(context, s) {
    context.beginPath()
    circle(context, 0.5 * s, 0.5 * s, 0.45 * s)
    context.fill()
    context.save()
    context.globalCompositeOperation = "destination-out"
    context.beginPath()
    context.moveTo(0.30 * s, 0.22 * s)
    context.bezierCurveTo(0.44 * s, 0.18 * s, 0.56 * s, 0.30 * s, 0.50 * s, 0.42 * s)
    context.bezierCurveTo(0.44 * s, 0.50 * s, 0.34 * s, 0.46 * s, 0.30 * s, 0.56 * s)
    context.bezierCurveTo(0.26 * s, 0.66 * s, 0.34 * s, 0.76 * s, 0.30 * s, 0.84 * s)
    context.bezierCurveTo(0.18 * s, 0.76 * s, 0.12 * s, 0.60 * s, 0.14 * s, 0.44 * s)
    context.bezierCurveTo(0.16 * s, 0.32 * s, 0.22 * s, 0.24 * s, 0.30 * s, 0.22 * s)
    context.closePath()
    context.moveTo(0.60 * s, 0.56 * s)
    context.bezierCurveTo(0.70 * s, 0.52 * s, 0.80 * s, 0.60 * s, 0.76 * s, 0.70 * s)
    context.bezierCurveTo(0.72 * s, 0.80 * s, 0.60 * s, 0.82 * s, 0.56 * s, 0.72 * s)
    context.bezierCurveTo(0.52 * s, 0.66 * s, 0.54 * s, 0.58 * s, 0.60 * s, 0.56 * s)
    context.closePath()
    context.fill()
    context.restore()
}

function eyeFill(context, s) {
    context.beginPath()
    context.moveTo(0.04 * s, 0.50 * s)
    context.bezierCurveTo(0.24 * s, 0.18 * s, 0.76 * s, 0.18 * s, 0.96 * s, 0.50 * s)
    context.bezierCurveTo(0.76 * s, 0.82 * s, 0.24 * s, 0.82 * s, 0.04 * s, 0.50 * s)
    context.closePath()
    context.fill()
    context.save()
    context.globalCompositeOperation = "destination-out"
    context.beginPath()
    circle(context, 0.5 * s, 0.5 * s, 0.17 * s)
    context.fill()
    context.restore()
    context.beginPath()
    circle(context, 0.5 * s, 0.5 * s, 0.10 * s)
    context.fill()
}

function crownFill(context, s) {
    context.beginPath()
    context.moveTo(0.08 * s, 0.30 * s)
    context.lineTo(0.30 * s, 0.52 * s)
    context.lineTo(0.50 * s, 0.18 * s)
    context.lineTo(0.70 * s, 0.52 * s)
    context.lineTo(0.92 * s, 0.30 * s)
    context.lineTo(0.84 * s, 0.76 * s)
    context.lineTo(0.16 * s, 0.76 * s)
    context.closePath()
    context.fill()
    context.beginPath()
    context.roundedRect(0.16 * s, 0.80 * s, 0.68 * s, 0.10 * s, 0.03 * s, 0.03 * s)
    context.fill()
}

function trophyFill(context, s) {
    context.beginPath()
    context.moveTo(0.26 * s, 0.10 * s)
    context.lineTo(0.74 * s, 0.10 * s)
    context.bezierCurveTo(0.74 * s, 0.44 * s, 0.64 * s, 0.60 * s, 0.50 * s, 0.62 * s)
    context.bezierCurveTo(0.36 * s, 0.60 * s, 0.26 * s, 0.44 * s, 0.26 * s, 0.10 * s)
    context.closePath()
    context.fill()
    context.beginPath()
    context.moveTo(0.26 * s, 0.20 * s)
    context.bezierCurveTo(0.08 * s, 0.20 * s, 0.08 * s, 0.48 * s, 0.30 * s, 0.50 * s)
    context.moveTo(0.74 * s, 0.20 * s)
    context.bezierCurveTo(0.92 * s, 0.20 * s, 0.92 * s, 0.48 * s, 0.70 * s, 0.50 * s)
    context.moveTo(0.50 * s, 0.62 * s)
    context.lineTo(0.50 * s, 0.78 * s)
    context.stroke()
    context.beginPath()
    context.roundedRect(0.32 * s, 0.78 * s, 0.36 * s, 0.12 * s, 0.03 * s, 0.03 * s)
    context.fill()
}

function gamecontrollerFill(context, s) {
    context.beginPath()
    context.moveTo(0.26 * s, 0.30 * s)
    context.lineTo(0.74 * s, 0.30 * s)
    context.bezierCurveTo(0.88 * s, 0.30 * s, 0.96 * s, 0.48 * s, 0.94 * s, 0.66 * s)
    context.bezierCurveTo(0.92 * s, 0.78 * s, 0.80 * s, 0.80 * s, 0.74 * s, 0.68 * s)
    context.lineTo(0.68 * s, 0.60 * s)
    context.lineTo(0.32 * s, 0.60 * s)
    context.lineTo(0.26 * s, 0.68 * s)
    context.bezierCurveTo(0.20 * s, 0.80 * s, 0.08 * s, 0.78 * s, 0.06 * s, 0.66 * s)
    context.bezierCurveTo(0.04 * s, 0.48 * s, 0.12 * s, 0.30 * s, 0.26 * s, 0.30 * s)
    context.closePath()
    context.fill()
    context.save()
    context.globalCompositeOperation = "destination-out"
    context.beginPath()
    context.rect(0.26 * s, 0.42 * s, 0.05 * s, 0.14 * s)
    context.rect(0.215 * s, 0.465 * s, 0.14 * s, 0.05 * s)
    circle(context, 0.68 * s, 0.44 * s, 0.03 * s)
    circle(context, 0.76 * s, 0.50 * s, 0.03 * s)
    context.fill()
    context.restore()
}

function musicNote(context, s) {
    context.beginPath()
    context.ellipse(0.16 * s, 0.66 * s, 0.30 * s, 0.22 * s)
    context.fill()
    context.beginPath()
    context.moveTo(0.44 * s, 0.76 * s)
    context.lineTo(0.44 * s, 0.10 * s)
    context.lineTo(0.82 * s, 0.20 * s)
    context.lineTo(0.82 * s, 0.34 * s)
    context.lineTo(0.52 * s, 0.26 * s)
    context.lineTo(0.52 * s, 0.76 * s)
    context.closePath()
    context.fill()
}

function paintbrushFill(context, s) {
    context.beginPath()
    context.moveTo(0.90 * s, 0.10 * s)
    context.lineTo(0.42 * s, 0.56 * s)
    context.lineTo(0.30 * s, 0.44 * s)
    context.lineTo(0.78 * s, 0.02 * s)
    context.closePath()
    context.fill()
    context.beginPath()
    context.moveTo(0.28 * s, 0.50 * s)
    context.bezierCurveTo(0.14 * s, 0.50 * s, 0.14 * s, 0.70 * s, 0.06 * s, 0.86 * s)
    context.bezierCurveTo(0.30 * s, 0.90 * s, 0.50 * s, 0.80 * s, 0.44 * s, 0.62 * s)
    context.closePath()
    context.fill()
}

function cameraFill(context, s) {
    context.beginPath()
    context.roundedRect(0.06 * s, 0.26 * s, 0.88 * s, 0.58 * s, 0.10 * s, 0.10 * s)
    context.fill()
    context.beginPath()
    context.moveTo(0.34 * s, 0.26 * s)
    context.lineTo(0.40 * s, 0.14 * s)
    context.lineTo(0.60 * s, 0.14 * s)
    context.lineTo(0.66 * s, 0.26 * s)
    context.closePath()
    context.fill()
    context.save()
    context.globalCompositeOperation = "destination-out"
    context.beginPath()
    circle(context, 0.5 * s, 0.55 * s, 0.18 * s)
    context.fill()
    context.restore()
    context.beginPath()
    circle(context, 0.5 * s, 0.55 * s, 0.11 * s)
    context.fill()
}

function headphones(context, s) {
    context.beginPath()
    context.arc(0.5 * s, 0.52 * s, 0.38 * s, Math.PI, 2 * Math.PI)
    context.stroke()
    context.beginPath()
    context.roundedRect(0.08 * s, 0.54 * s, 0.18 * s, 0.30 * s, 0.06 * s, 0.06 * s)
    context.roundedRect(0.74 * s, 0.54 * s, 0.18 * s, 0.30 * s, 0.06 * s, 0.06 * s)
    context.fill()
}

function theatermasksFill(context, s) {
    function mask(x, y, w, h, smile) {
        context.beginPath()
        context.moveTo(x, y)
        context.lineTo(x + w, y)
        context.bezierCurveTo(x + w, y + h * 0.9, x + w * 0.5, y + h, x + w * 0.5, y + h)
        context.bezierCurveTo(x + w * 0.5, y + h, x, y + h * 0.9, x, y)
        context.closePath()
        context.fill()
        context.save()
        context.globalCompositeOperation = "destination-out"
        context.beginPath()
        context.ellipse(x + w * 0.18, y + h * 0.22, w * 0.22, h * 0.14)
        context.ellipse(x + w * 0.60, y + h * 0.22, w * 0.22, h * 0.14)
        context.fill()
        context.beginPath()
        if (smile) {
            context.arc(x + w * 0.5, y + h * 0.52, w * 0.22, 0.15 * Math.PI, 0.85 * Math.PI)
        } else {
            context.arc(x + w * 0.5, y + h * 0.80, w * 0.22, 1.15 * Math.PI, 1.85 * Math.PI)
        }
        context.lineWidth = Math.max(1, s * 0.05)
        context.stroke()
        context.restore()
    }
    mask(0.04 * s, 0.14 * s, 0.56 * s, 0.62 * s, true)
    mask(0.40 * s, 0.30 * s, 0.56 * s, 0.62 * s, false)
}

function faceSmiling(context, s) {
    context.beginPath()
    circle(context, 0.5 * s, 0.5 * s, 0.44 * s)
    context.stroke()
    context.beginPath()
    circle(context, 0.36 * s, 0.40 * s, 0.05 * s)
    circle(context, 0.64 * s, 0.40 * s, 0.05 * s)
    context.fill()
    context.beginPath()
    context.arc(0.5 * s, 0.54 * s, 0.24 * s, 0.15 * Math.PI, 0.85 * Math.PI)
    context.stroke()
}

function airplane(context, s) {
    context.beginPath()
    context.moveTo(0.94 * s, 0.50 * s)
    context.lineTo(0.62 * s, 0.42 * s)
    context.lineTo(0.30 * s, 0.10 * s)
    context.lineTo(0.20 * s, 0.10 * s)
    context.lineTo(0.38 * s, 0.42 * s)
    context.lineTo(0.16 * s, 0.42 * s)
    context.lineTo(0.06 * s, 0.30 * s)
    context.lineTo(0.02 * s, 0.30 * s)
    context.lineTo(0.06 * s, 0.50 * s)
    context.lineTo(0.02 * s, 0.70 * s)
    context.lineTo(0.06 * s, 0.70 * s)
    context.lineTo(0.16 * s, 0.58 * s)
    context.lineTo(0.38 * s, 0.58 * s)
    context.lineTo(0.20 * s, 0.90 * s)
    context.lineTo(0.30 * s, 0.90 * s)
    context.lineTo(0.62 * s, 0.58 * s)
    context.closePath()
    context.fill()
}

// Animals: silhouettes, all filled.

function catFill(context, s) {
    context.beginPath()
    context.moveTo(0.14 * s, 0.10 * s)
    context.lineTo(0.30 * s, 0.30 * s)
    context.lineTo(0.70 * s, 0.30 * s)
    context.lineTo(0.86 * s, 0.10 * s)
    context.lineTo(0.90 * s, 0.56 * s)
    context.bezierCurveTo(0.90 * s, 0.80 * s, 0.72 * s, 0.94 * s, 0.50 * s, 0.94 * s)
    context.bezierCurveTo(0.28 * s, 0.94 * s, 0.10 * s, 0.80 * s, 0.10 * s, 0.56 * s)
    context.closePath()
    context.fill()
    context.save()
    context.globalCompositeOperation = "destination-out"
    context.beginPath()
    context.ellipse(0.28 * s, 0.50 * s, 0.14 * s, 0.10 * s)
    context.ellipse(0.58 * s, 0.50 * s, 0.14 * s, 0.10 * s)
    context.fill()
    context.restore()
}

function dogFill(context, s) {
    context.beginPath()
    context.moveTo(0.26 * s, 0.14 * s)
    context.lineTo(0.74 * s, 0.14 * s)
    context.bezierCurveTo(0.94 * s, 0.14 * s, 0.96 * s, 0.44 * s, 0.86 * s, 0.50 * s)
    context.lineTo(0.84 * s, 0.68 * s)
    context.bezierCurveTo(0.82 * s, 0.86 * s, 0.66 * s, 0.94 * s, 0.50 * s, 0.94 * s)
    context.bezierCurveTo(0.34 * s, 0.94 * s, 0.18 * s, 0.86 * s, 0.16 * s, 0.68 * s)
    context.lineTo(0.14 * s, 0.50 * s)
    context.bezierCurveTo(0.04 * s, 0.44 * s, 0.06 * s, 0.14 * s, 0.26 * s, 0.14 * s)
    context.closePath()
    context.fill()
    context.save()
    context.globalCompositeOperation = "destination-out"
    context.beginPath()
    circle(context, 0.38 * s, 0.46 * s, 0.05 * s)
    circle(context, 0.62 * s, 0.46 * s, 0.05 * s)
    context.ellipse(0.40 * s, 0.62 * s, 0.20 * s, 0.14 * s)
    context.fill()
    context.restore()
}

function hareFill(context, s) {
    context.beginPath()
    context.ellipse(0.30 * s, 0.02 * s, 0.14 * s, 0.44 * s)
    context.ellipse(0.56 * s, 0.02 * s, 0.14 * s, 0.44 * s)
    context.fill()
    context.beginPath()
    context.ellipse(0.16 * s, 0.40 * s, 0.68 * s, 0.56 * s)
    context.fill()
    context.save()
    context.globalCompositeOperation = "destination-out"
    context.beginPath()
    circle(context, 0.40 * s, 0.62 * s, 0.05 * s)
    circle(context, 0.60 * s, 0.62 * s, 0.05 * s)
    context.fill()
    context.restore()
}

function tortoiseFill(context, s) {
    context.beginPath()
    context.moveTo(0.16 * s, 0.62 * s)
    context.bezierCurveTo(0.16 * s, 0.30 * s, 0.84 * s, 0.30 * s, 0.84 * s, 0.62 * s)
    context.closePath()
    context.fill()
    context.beginPath()
    context.roundedRect(0.06 * s, 0.60 * s, 0.88 * s, 0.14 * s, 0.07 * s, 0.07 * s)
    context.fill()
    context.beginPath()
    circle(context, 0.10 * s, 0.56 * s, 0.09 * s)
    context.fill()
    context.beginPath()
    context.rect(0.24 * s, 0.72 * s, 0.10 * s, 0.14 * s)
    context.rect(0.66 * s, 0.72 * s, 0.10 * s, 0.14 * s)
    context.fill()
}

function birdFill(context, s) {
    context.beginPath()
    context.moveTo(0.10 * s, 0.56 * s)
    context.bezierCurveTo(0.30 * s, 0.30 * s, 0.60 * s, 0.30 * s, 0.70 * s, 0.34 * s)
    context.bezierCurveTo(0.72 * s, 0.22 * s, 0.86 * s, 0.22 * s, 0.88 * s, 0.34 * s)
    context.lineTo(0.98 * s, 0.38 * s)
    context.lineTo(0.88 * s, 0.42 * s)
    context.bezierCurveTo(0.86 * s, 0.70 * s, 0.60 * s, 0.86 * s, 0.32 * s, 0.80 * s)
    context.lineTo(0.44 * s, 0.94 * s)
    context.lineTo(0.28 * s, 0.94 * s)
    context.lineTo(0.22 * s, 0.76 * s)
    context.bezierCurveTo(0.14 * s, 0.70 * s, 0.10 * s, 0.62 * s, 0.10 * s, 0.56 * s)
    context.closePath()
    context.fill()
}

function fishFill(context, s) {
    context.beginPath()
    context.moveTo(0.10 * s, 0.50 * s)
    context.bezierCurveTo(0.30 * s, 0.20 * s, 0.62 * s, 0.20 * s, 0.78 * s, 0.50 * s)
    context.bezierCurveTo(0.62 * s, 0.80 * s, 0.30 * s, 0.80 * s, 0.10 * s, 0.50 * s)
    context.closePath()
    context.moveTo(0.76 * s, 0.50 * s)
    context.lineTo(0.96 * s, 0.30 * s)
    context.lineTo(0.96 * s, 0.70 * s)
    context.closePath()
    context.fill()
    context.save()
    context.globalCompositeOperation = "destination-out"
    context.beginPath()
    circle(context, 0.28 * s, 0.44 * s, 0.04 * s)
    context.fill()
    context.restore()
}

function antFill(context, s) {
    context.beginPath()
    context.ellipse(0.06 * s, 0.38 * s, 0.24 * s, 0.24 * s)
    context.ellipse(0.32 * s, 0.40 * s, 0.22 * s, 0.20 * s)
    context.ellipse(0.56 * s, 0.34 * s, 0.38 * s, 0.32 * s)
    context.fill()
    context.beginPath()
    context.moveTo(0.20 * s, 0.40 * s); context.lineTo(0.08 * s, 0.20 * s)
    context.moveTo(0.26 * s, 0.40 * s); context.lineTo(0.22 * s, 0.18 * s)
    for (let leg = 0; leg < 3; ++leg) {
        const x = (0.40 + 0.14 * leg) * s
        context.moveTo(x, 0.54 * s); context.lineTo(x - 0.10 * s, 0.84 * s)
        context.moveTo(x, 0.42 * s); context.lineTo(x - 0.06 * s, 0.14 * s)
    }
    context.stroke()
}

function ladybugFill(context, s) {
    context.beginPath()
    circle(context, 0.5 * s, 0.56 * s, 0.38 * s)
    context.fill()
    context.beginPath()
    circle(context, 0.5 * s, 0.22 * s, 0.14 * s)
    context.fill()
    context.save()
    context.globalCompositeOperation = "destination-out"
    context.beginPath()
    context.rect(0.485 * s, 0.30 * s, 0.03 * s, 0.64 * s)
    circle(context, 0.34 * s, 0.50 * s, 0.06 * s)
    circle(context, 0.66 * s, 0.50 * s, 0.06 * s)
    circle(context, 0.36 * s, 0.74 * s, 0.05 * s)
    circle(context, 0.64 * s, 0.74 * s, 0.05 * s)
    context.fill()
    context.restore()
}

function mountain2Fill(context, s) {
    context.beginPath()
    context.moveTo(0.02 * s, 0.86 * s)
    context.lineTo(0.30 * s, 0.34 * s)
    context.lineTo(0.44 * s, 0.56 * s)
    context.lineTo(0.62 * s, 0.16 * s)
    context.lineTo(0.98 * s, 0.86 * s)
    context.closePath()
    context.fill()
}

// Editing glyphs.

function plusCircle(context, s) {
    context.beginPath()
    circle(context, 0.5 * s, 0.5 * s, 0.45 * s)
    context.moveTo(0.5 * s, 0.28 * s)
    context.lineTo(0.5 * s, 0.72 * s)
    context.moveTo(0.28 * s, 0.5 * s)
    context.lineTo(0.72 * s, 0.5 * s)
    context.stroke()
}

function pencil(context, s) {
    context.beginPath()
    context.moveTo(0.14 * s, 0.86 * s)
    context.lineTo(0.16 * s, 0.66 * s)
    context.lineTo(0.70 * s, 0.12 * s)
    context.lineTo(0.88 * s, 0.30 * s)
    context.lineTo(0.34 * s, 0.84 * s)
    context.closePath()
    context.moveTo(0.60 * s, 0.22 * s)
    context.lineTo(0.78 * s, 0.40 * s)
    context.stroke()
}

function trash(context, s) {
    context.beginPath()
    context.moveTo(0.14 * s, 0.24 * s)
    context.lineTo(0.86 * s, 0.24 * s)
    context.moveTo(0.36 * s, 0.24 * s)
    context.lineTo(0.36 * s, 0.12 * s)
    context.lineTo(0.64 * s, 0.12 * s)
    context.lineTo(0.64 * s, 0.24 * s)
    context.moveTo(0.22 * s, 0.24 * s)
    context.lineTo(0.28 * s, 0.90 * s)
    context.lineTo(0.72 * s, 0.90 * s)
    context.lineTo(0.78 * s, 0.24 * s)
    context.moveTo(0.42 * s, 0.38 * s)
    context.lineTo(0.44 * s, 0.76 * s)
    context.moveTo(0.58 * s, 0.38 * s)
    context.lineTo(0.56 * s, 0.76 * s)
    context.stroke()
}

function chevronLeft(context, s) {
    context.beginPath()
    context.moveTo(0.64 * s, 0.14 * s)
    context.lineTo(0.30 * s, 0.50 * s)
    context.lineTo(0.64 * s, 0.86 * s)
    context.stroke()
}

function chevronRight(context, s) {
    context.beginPath()
    context.moveTo(0.36 * s, 0.14 * s)
    context.lineTo(0.70 * s, 0.50 * s)
    context.lineTo(0.36 * s, 0.86 * s)
    context.stroke()
}

function xmark(context, s) {
    context.beginPath()
    context.moveTo(0.20 * s, 0.20 * s)
    context.lineTo(0.80 * s, 0.80 * s)
    context.moveTo(0.80 * s, 0.20 * s)
    context.lineTo(0.20 * s, 0.80 * s)
    context.stroke()
}

// Settings glyphs.

function roundedRect(context, x, y, w, h, r) {
    context.moveTo(x + r, y)
    context.lineTo(x + w - r, y)
    context.arcTo(x + w, y, x + w, y + r, r)
    context.lineTo(x + w, y + h - r)
    context.arcTo(x + w, y + h, x + w - r, y + h, r)
    context.lineTo(x + r, y + h)
    context.arcTo(x, y + h, x, y + h - r, r)
    context.lineTo(x, y + r)
    context.arcTo(x, y, x + r, y, r)
    context.closePath()
}

function folderFill(context, s) {
    context.beginPath()
    context.moveTo(0.08 * s, 0.22 * s)
    context.lineTo(0.36 * s, 0.22 * s)
    context.lineTo(0.44 * s, 0.32 * s)
    context.lineTo(0.92 * s, 0.32 * s)
    context.lineTo(0.92 * s, 0.80 * s)
    context.lineTo(0.08 * s, 0.80 * s)
    context.closePath()
    context.fill()
}

function folder(context, s) {
    context.beginPath()
    context.moveTo(0.10 * s, 0.24 * s)
    context.lineTo(0.36 * s, 0.24 * s)
    context.lineTo(0.44 * s, 0.34 * s)
    context.lineTo(0.90 * s, 0.34 * s)
    context.lineTo(0.90 * s, 0.78 * s)
    context.lineTo(0.10 * s, 0.78 * s)
    context.closePath()
    context.stroke()
}

function folderBadgeQuestionmark(context, s) {
    folder(context, s)
    context.beginPath()
    context.arc(0.74 * s, 0.70 * s, 0.20 * s, 0, 2 * Math.PI)
    context.fill()
    context.save()
    context.strokeStyle = "#000000"
    context.lineWidth = Math.max(1, s * 0.06)
    context.beginPath()
    context.arc(0.74 * s, 0.64 * s, 0.07 * s, Math.PI * 1.05, Math.PI * 2.45)
    context.lineTo(0.74 * s, 0.75 * s)
    context.moveTo(0.74 * s, 0.81 * s)
    context.lineTo(0.74 * s, 0.82 * s)
    context.stroke()
    context.restore()
}

function externaldrive(context, s) {
    context.beginPath()
    roundedRect(context, 0.10 * s, 0.30 * s, 0.80 * s, 0.40 * s, 0.06 * s)
    context.moveTo(0.10 * s, 0.55 * s)
    context.lineTo(0.90 * s, 0.55 * s)
    context.stroke()
    context.beginPath()
    context.arc(0.78 * s, 0.63 * s, 0.035 * s, 0, 2 * Math.PI)
    context.fill()
}

function internaldriveFill(context, s) {
    context.beginPath()
    roundedRect(context, 0.08 * s, 0.30 * s, 0.84 * s, 0.40 * s, 0.06 * s)
    context.fill()
    context.save()
    context.fillStyle = "#000000"
    context.beginPath()
    context.arc(0.78 * s, 0.58 * s, 0.045 * s, 0, 2 * Math.PI)
    context.fill()
    context.restore()
}

function playRectangleFill(context, s) {
    context.beginPath()
    roundedRect(context, 0.08 * s, 0.20 * s, 0.84 * s, 0.60 * s, 0.10 * s)
    context.fill()
    context.save()
    context.fillStyle = "#000000"
    context.beginPath()
    context.moveTo(0.40 * s, 0.34 * s)
    context.lineTo(0.66 * s, 0.50 * s)
    context.lineTo(0.40 * s, 0.66 * s)
    context.closePath()
    context.fill()
    context.restore()
}

function speakerWave2Fill(context, s) {
    context.beginPath()
    context.moveTo(0.10 * s, 0.38 * s)
    context.lineTo(0.26 * s, 0.38 * s)
    context.lineTo(0.46 * s, 0.20 * s)
    context.lineTo(0.46 * s, 0.80 * s)
    context.lineTo(0.26 * s, 0.62 * s)
    context.lineTo(0.10 * s, 0.62 * s)
    context.closePath()
    context.fill()
    context.beginPath()
    context.arc(0.50 * s, 0.50 * s, 0.16 * s, -Math.PI * 0.3, Math.PI * 0.3)
    context.stroke()
    context.beginPath()
    context.arc(0.50 * s, 0.50 * s, 0.30 * s, -Math.PI * 0.32, Math.PI * 0.32)
    context.stroke()
}

function sparkles(context, s) {
    context.beginPath()
    star(context, 0.40 * s, 0.56 * s, 0.34 * s, 0.10 * s, 4)
    context.fill()
    context.beginPath()
    star(context, 0.76 * s, 0.24 * s, 0.14 * s, 0.045 * s, 4)
    context.fill()
    context.beginPath()
    star(context, 0.78 * s, 0.76 * s, 0.11 * s, 0.035 * s, 4)
    context.fill()
}

function arrowClockwise(context, s) {
    context.beginPath()
    context.arc(0.50 * s, 0.52 * s, 0.32 * s, -Math.PI * 0.30, Math.PI * 1.42)
    context.stroke()
    context.beginPath()
    context.moveTo(0.60 * s, 0.10 * s)
    context.lineTo(0.72 * s, 0.30 * s)
    context.lineTo(0.50 * s, 0.34 * s)
    context.closePath()
    context.fill()
}

function arrowTriangle2Circlepath(context, s) {
    context.beginPath()
    context.arc(0.50 * s, 0.50 * s, 0.32 * s, Math.PI * 1.15, Math.PI * 1.85)
    context.stroke()
    context.beginPath()
    context.arc(0.50 * s, 0.50 * s, 0.32 * s, Math.PI * 0.15, Math.PI * 0.85)
    context.stroke()
    context.beginPath()
    context.moveTo(0.86 * s, 0.26 * s)
    context.lineTo(0.86 * s, 0.48 * s)
    context.lineTo(0.66 * s, 0.40 * s)
    context.closePath()
    context.fill()
    context.beginPath()
    context.moveTo(0.14 * s, 0.74 * s)
    context.lineTo(0.14 * s, 0.52 * s)
    context.lineTo(0.34 * s, 0.60 * s)
    context.closePath()
    context.fill()
}

function checkmarkSealFill(context, s) {
    context.beginPath()
    star(context, 0.50 * s, 0.50 * s, 0.46 * s, 0.40 * s, 12)
    context.fill()
    context.save()
    context.strokeStyle = "#000000"
    context.lineWidth = Math.max(1, s * 0.09)
    context.beginPath()
    context.moveTo(0.32 * s, 0.52 * s)
    context.lineTo(0.45 * s, 0.65 * s)
    context.lineTo(0.70 * s, 0.36 * s)
    context.stroke()
    context.restore()
}

function minusCircleFill(context, s) {
    context.beginPath()
    circle(context, 0.5 * s, 0.5 * s, 0.45 * s)
    context.fill()
    context.save()
    context.strokeStyle = "#000000"
    context.lineWidth = Math.max(1, s * 0.10)
    context.beginPath()
    context.moveTo(0.30 * s, 0.50 * s)
    context.lineTo(0.70 * s, 0.50 * s)
    context.stroke()
    context.restore()
}

function plus(context, s) {
    context.beginPath()
    context.moveTo(0.5 * s, 0.16 * s)
    context.lineTo(0.5 * s, 0.84 * s)
    context.moveTo(0.16 * s, 0.5 * s)
    context.lineTo(0.84 * s, 0.5 * s)
    context.stroke()
}

function squareAndArrowUp(context, s) {
    context.beginPath()
    context.moveTo(0.36 * s, 0.40 * s)
    context.lineTo(0.18 * s, 0.40 * s)
    context.lineTo(0.18 * s, 0.88 * s)
    context.lineTo(0.82 * s, 0.88 * s)
    context.lineTo(0.82 * s, 0.40 * s)
    context.lineTo(0.64 * s, 0.40 * s)
    context.moveTo(0.50 * s, 0.62 * s)
    context.lineTo(0.50 * s, 0.10 * s)
    context.moveTo(0.34 * s, 0.26 * s)
    context.lineTo(0.50 * s, 0.10 * s)
    context.lineTo(0.66 * s, 0.26 * s)
    context.stroke()
}

// captions.bubble: a speech bubble with its tail at the bottom left and two
// caption lines inside. The filled variant cuts the lines out in black, the
// way the other filled symbols here cut theirs, because the HUD draws it over
// black.
function captionsBubbleOutline(context, s) {
    context.beginPath()
    roundedRect(context, 0.06 * s, 0.14 * s, 0.88 * s, 0.62 * s, 0.14 * s)
    context.moveTo(0.26 * s, 0.76 * s)
    context.lineTo(0.22 * s, 0.90 * s)
    context.lineTo(0.42 * s, 0.76 * s)
    context.stroke()
    captionLines(context, s)
    context.stroke()
}

function captionLines(context, s) {
    context.beginPath()
    context.moveTo(0.22 * s, 0.38 * s)
    context.lineTo(0.40 * s, 0.38 * s)
    context.moveTo(0.50 * s, 0.38 * s)
    context.lineTo(0.78 * s, 0.38 * s)
    context.moveTo(0.22 * s, 0.54 * s)
    context.lineTo(0.56 * s, 0.54 * s)
    context.moveTo(0.64 * s, 0.54 * s)
    context.lineTo(0.78 * s, 0.54 * s)
}

function captionsBubbleFill(context, s) {
    context.beginPath()
    roundedRect(context, 0.06 * s, 0.14 * s, 0.88 * s, 0.62 * s, 0.14 * s)
    context.moveTo(0.26 * s, 0.74 * s)
    context.lineTo(0.22 * s, 0.90 * s)
    context.lineTo(0.44 * s, 0.74 * s)
    context.closePath()
    context.fill()
    context.save()
    context.strokeStyle = "#000000"
    captionLines(context, s)
    context.stroke()
    context.restore()
}

// speaker.wave.2: the outlined speaker with two sound arcs.
function speakerWave2(context, s) {
    context.beginPath()
    context.moveTo(0.10 * s, 0.38 * s)
    context.lineTo(0.26 * s, 0.38 * s)
    context.lineTo(0.46 * s, 0.20 * s)
    context.lineTo(0.46 * s, 0.80 * s)
    context.lineTo(0.26 * s, 0.62 * s)
    context.lineTo(0.10 * s, 0.62 * s)
    context.closePath()
    context.stroke()
    context.beginPath()
    context.arc(0.50 * s, 0.50 * s, 0.16 * s, -Math.PI * 0.3, Math.PI * 0.3)
    context.stroke()
    context.beginPath()
    context.arc(0.50 * s, 0.50 * s, 0.30 * s, -Math.PI * 0.32, Math.PI * 0.32)
    context.stroke()
}

// Player transport glyphs: PlayerControlsOverlay.swift:324-330, :405-411,
// :546-570.
function backwardEnd(context, s) {
    context.beginPath()
    context.moveTo(0.24 * s, 0.22 * s)
    context.lineTo(0.24 * s, 0.78 * s)
    context.stroke()
    context.beginPath()
    context.moveTo(0.78 * s, 0.22 * s)
    context.lineTo(0.38 * s, 0.50 * s)
    context.lineTo(0.78 * s, 0.78 * s)
    context.closePath()
    context.stroke()
}

// forward.end: backward.end mirrored, the Next Episode glyph
// (PlayerControlsOverlay.swift:353-362).
function forwardEnd(context, s) {
    context.beginPath()
    context.moveTo(0.76 * s, 0.22 * s)
    context.lineTo(0.76 * s, 0.78 * s)
    context.stroke()
    context.beginPath()
    context.moveTo(0.22 * s, 0.22 * s)
    context.lineTo(0.62 * s, 0.50 * s)
    context.lineTo(0.22 * s, 0.78 * s)
    context.closePath()
    context.stroke()
}

// gobackward: an open circular arrow, its head at the top pointing the way the
// arc runs back around. The number sits inside, drawn by the owner.
function goBackward(context, s) {
    const centerX = 0.5 * s
    const centerY = 0.54 * s
    const radius = 0.34 * s
    const start = -Math.PI / 2 + 0.35
    context.beginPath()
    context.arc(centerX, centerY, radius, start, start + 2 * Math.PI - 1.0, false)
    context.stroke()
    const tipX = centerX + radius * Math.cos(start)
    const tipY = centerY + radius * Math.sin(start)
    context.beginPath()
    context.moveTo(tipX + 0.02 * s, tipY - 0.14 * s)
    context.lineTo(tipX - 0.01 * s, tipY)
    context.lineTo(tipX + 0.15 * s, tipY + 0.07 * s)
    context.stroke()
}

function goForward(context, s) {
    context.save()
    context.translate(s, 0)
    context.scale(-1, 1)
    goBackward(context, s)
    context.restore()
}

function playFill(context, s) {
    context.beginPath()
    context.moveTo(0.30 * s, 0.16 * s)
    context.lineTo(0.84 * s, 0.50 * s)
    context.lineTo(0.30 * s, 0.84 * s)
    context.closePath()
    context.fill()
}

function pauseFill(context, s) {
    context.beginPath()
    roundedRect(context, 0.22 * s, 0.16 * s, 0.20 * s, 0.68 * s, 0.05 * s)
    roundedRect(context, 0.58 * s, 0.16 * s, 0.20 * s, 0.68 * s, 0.05 * s)
    context.fill()
}

function speakerBody(context, s) {
    context.beginPath()
    context.moveTo(0.10 * s, 0.38 * s)
    context.lineTo(0.26 * s, 0.38 * s)
    context.lineTo(0.46 * s, 0.20 * s)
    context.lineTo(0.46 * s, 0.80 * s)
    context.lineTo(0.26 * s, 0.62 * s)
    context.lineTo(0.10 * s, 0.62 * s)
    context.closePath()
    context.fill()
}

function speakerSlashFill(context, s) {
    speakerBody(context, s)
    context.beginPath()
    context.moveTo(0.60 * s, 0.38 * s)
    context.lineTo(0.88 * s, 0.62 * s)
    context.moveTo(0.88 * s, 0.38 * s)
    context.lineTo(0.60 * s, 0.62 * s)
    context.stroke()
}

function speakerWave1Fill(context, s) {
    speakerBody(context, s)
    context.beginPath()
    context.arc(0.50 * s, 0.50 * s, 0.16 * s, -Math.PI * 0.3, Math.PI * 0.3)
    context.stroke()
}

function speakerWave3Fill(context, s) {
    speakerWave2Fill(context, s)
    context.beginPath()
    context.arc(0.50 * s, 0.50 * s, 0.44 * s, -Math.PI * 0.32, Math.PI * 0.32)
    context.stroke()
}

function arrowUpLeftAndDownRight(context, s) {
    context.beginPath()
    context.moveTo(0.22 * s, 0.22 * s)
    context.lineTo(0.78 * s, 0.78 * s)
    context.moveTo(0.22 * s, 0.22 * s)
    context.lineTo(0.22 * s, 0.44 * s)
    context.moveTo(0.22 * s, 0.22 * s)
    context.lineTo(0.44 * s, 0.22 * s)
    context.moveTo(0.78 * s, 0.78 * s)
    context.lineTo(0.78 * s, 0.56 * s)
    context.moveTo(0.78 * s, 0.78 * s)
    context.lineTo(0.56 * s, 0.78 * s)
    context.stroke()
}

var painters = {
    "folder.fill": folderFill,
    "folder": folder,
    "folder.badge.questionmark": folderBadgeQuestionmark,
    "externaldrive": externaldrive,
    "internaldrive.fill": internaldriveFill,
    "play.rectangle.fill": playRectangleFill,
    "speaker.wave.2.fill": speakerWave2Fill,
    "speaker.wave.2": speakerWave2,
    "speaker.wave.1.fill": speakerWave1Fill,
    "speaker.wave.3.fill": speakerWave3Fill,
    "speaker.slash.fill": speakerSlashFill,
    "backward.end": backwardEnd,
    "forward.end": forwardEnd,
    "gobackward": goBackward,
    "goforward": goForward,
    "play.fill": playFill,
    "pause.fill": pauseFill,
    "arrow.up.left.and.arrow.down.right": arrowUpLeftAndDownRight,
    "captions.bubble": captionsBubbleOutline,
    "captions.bubble.fill": captionsBubbleFill,
    "sparkles": sparkles,
    "arrow.clockwise": arrowClockwise,
    "arrow.triangle.2.circlepath": arrowTriangle2Circlepath,
    "checkmark.seal.fill": checkmarkSealFill,
    "minus.circle.fill": minusCircleFill,
    "plus": plus,
    "square.and.arrow.up": squareAndArrowUp,
    "heart.fill": heart,
    "star.fill": starFill,
    "moon.fill": moonFill,
    "sun.max.fill": sunMaxFill,
    "bolt.fill": boltFill,
    "flame.fill": flameFill,
    "leaf.fill": leafFill,
    "snowflake": snowflake,
    "cloud.fill": cloudFill,
    "globe.americas.fill": globeAmericasFill,
    "eye.fill": eyeFill,
    "crown.fill": crownFill,
    "trophy.fill": trophyFill,
    "gamecontroller.fill": gamecontrollerFill,
    "music.note": musicNote,
    "paintbrush.fill": paintbrushFill,
    "camera.fill": cameraFill,
    "headphones": headphones,
    "theatermasks.fill": theatermasksFill,
    "face.smiling": faceSmiling,
    "airplane": airplane,
    "cat.fill": catFill,
    "dog.fill": dogFill,
    "hare.fill": hareFill,
    "tortoise.fill": tortoiseFill,
    "bird.fill": birdFill,
    "fish.fill": fishFill,
    "ant.fill": antFill,
    "ladybug.fill": ladybugFill,
    "mountain.2.fill": mountain2Fill,
    "plus.circle": plusCircle,
    "pencil": pencil,
    "trash": trash,
    "chevron.left": chevronLeft,
    "chevron.right": chevronRight,
    "xmark": xmark
}

function canPaint(symbol) {
    return painters.hasOwnProperty(symbol)
}

function paint(symbol, context, size) {
    painters[symbol](context, size)
}
