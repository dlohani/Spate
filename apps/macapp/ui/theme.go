// Package ui is Cascade's design system and desktop UI on top of Fyne: a small
// token set (colors, sizes) applied through a custom theme, and a card-based
// download list that updates in place. Pure Go, no webview, so it stays light
// and renders identically on every platform Fyne targets.
package ui

import (
	"image/color"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/theme"
)

// palette holds the design tokens for one variant.
type palette struct {
	bg, surface, border, text, muted, primary, primaryText, hover, pressed, focus, success, danger, warning, track color.Color
}

var light = palette{
	bg:          rgb(0xF6, 0xF7, 0xF9),
	surface:     rgb(0xFF, 0xFF, 0xFF),
	border:      rgb(0xE5, 0xE7, 0xEB),
	text:        rgb(0x11, 0x18, 0x27),
	muted:       rgb(0x6B, 0x72, 0x80),
	primary:     rgb(0x25, 0x63, 0xEB),
	primaryText: rgb(0xFF, 0xFF, 0xFF),
	hover:       rgba(0x11, 0x18, 0x27, 0x0A),
	pressed:     rgba(0x11, 0x18, 0x27, 0x14),
	focus:       rgba(0x25, 0x63, 0xEB, 0x55),
	success:     rgb(0x16, 0xA3, 0x4A),
	danger:      rgb(0xDC, 0x26, 0x26),
	warning:     rgb(0xD9, 0x77, 0x06),
	track:       rgb(0xE9, 0xEC, 0xF1),
}

var dark = palette{
	bg:          rgb(0x0F, 0x12, 0x17),
	surface:     rgb(0x17, 0x1B, 0x22),
	border:      rgb(0x2A, 0x30, 0x3A),
	text:        rgb(0xE6, 0xE8, 0xEC),
	muted:       rgb(0x9A, 0xA3, 0xB2),
	primary:     rgb(0x3B, 0x82, 0xF6),
	primaryText: rgb(0xFF, 0xFF, 0xFF),
	hover:       rgba(0xFF, 0xFF, 0xFF, 0x0D),
	pressed:     rgba(0xFF, 0xFF, 0xFF, 0x1A),
	focus:       rgba(0x3B, 0x82, 0xF6, 0x66),
	success:     rgb(0x22, 0xC5, 0x5E),
	danger:      rgb(0xEF, 0x44, 0x44),
	warning:     rgb(0xF5, 0x9E, 0x0B),
	track:       rgb(0x2A, 0x30, 0x3A),
}

func rgb(r, g, b uint8) color.Color         { return color.NRGBA{R: r, G: g, B: b, A: 0xFF} }
func rgba(r, g, b, a uint8) color.Color     { return color.NRGBA{R: r, G: g, B: b, A: a} }
func pal(v fyne.ThemeVariant) palette {
	if v == theme.VariantDark {
		return dark
	}
	return light
}

// Theme applies the tokens to Fyne. Fonts and icons are inherited from the
// default theme; only colors and sizing change.
type Theme struct{}

var _ fyne.Theme = Theme{}

func (Theme) Color(name fyne.ThemeColorName, v fyne.ThemeVariant) color.Color {
	p := pal(v)
	switch name {
	case theme.ColorNameBackground:
		return p.bg
	case theme.ColorNameForeground:
		return p.text
	case theme.ColorNamePrimary, theme.ColorNameHyperlink:
		return p.primary
	case theme.ColorNameForegroundOnPrimary:
		return p.primaryText
	case theme.ColorNameButton:
		return p.surface
	case theme.ColorNameDisabledButton:
		return p.track
	case theme.ColorNameDisabled:
		return p.muted
	case theme.ColorNamePlaceHolder:
		return p.muted
	case theme.ColorNameInputBackground, theme.ColorNameMenuBackground, theme.ColorNameOverlayBackground, theme.ColorNameHeaderBackground:
		return p.surface
	case theme.ColorNameInputBorder, theme.ColorNameSeparator:
		return p.border
	case theme.ColorNameHover:
		return p.hover
	case theme.ColorNamePressed:
		return p.pressed
	case theme.ColorNameFocus, theme.ColorNameSelection:
		return p.focus
	case theme.ColorNameSuccess:
		return p.success
	case theme.ColorNameError:
		return p.danger
	case theme.ColorNameWarning:
		return p.warning
	case theme.ColorNameScrollBar:
		return p.muted
	case theme.ColorNameShadow:
		return rgba(0, 0, 0, 0x22)
	}
	return theme.DefaultTheme().Color(name, v)
}

// ForcedVariant returns the design theme pinned to one variant regardless of
// the OS setting, so the theme colors and the view's palette always agree
// (used for a "force light/dark" preference and for headless snapshots).
func ForcedVariant(v fyne.ThemeVariant) fyne.Theme { return forced{v: v} }

type forced struct{ v fyne.ThemeVariant }

func (f forced) Color(n fyne.ThemeColorName, _ fyne.ThemeVariant) color.Color {
	return Theme{}.Color(n, f.v)
}
func (f forced) Font(s fyne.TextStyle) fyne.Resource     { return Theme{}.Font(s) }
func (f forced) Icon(n fyne.ThemeIconName) fyne.Resource { return Theme{}.Icon(n) }
func (f forced) Size(n fyne.ThemeSizeName) float32       { return Theme{}.Size(n) }

func (Theme) Font(s fyne.TextStyle) fyne.Resource   { return theme.DefaultTheme().Font(s) }
func (Theme) Icon(n fyne.ThemeIconName) fyne.Resource { return theme.DefaultTheme().Icon(n) }

func (Theme) Size(name fyne.ThemeSizeName) float32 {
	switch name {
	case theme.SizeNameText:
		return 13
	case theme.SizeNameHeadingText:
		return 20
	case theme.SizeNameSubHeadingText:
		return 15
	case theme.SizeNameCaptionText:
		return 11
	case theme.SizeNamePadding:
		return 6
	case theme.SizeNameInnerPadding:
		return 8
	case theme.SizeNameInputRadius:
		return 8
	case theme.SizeNameSelectionRadius:
		return 6
	case theme.SizeNameSeparatorThickness:
		return 1
	case theme.SizeNameInputBorder:
		return 1
	case theme.SizeNameScrollBar:
		return 8
	case theme.SizeNameScrollBarSmall:
		return 4
	}
	return theme.DefaultTheme().Size(name)
}
