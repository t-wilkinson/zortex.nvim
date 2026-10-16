package links

import "regexp"

var durationWord = regexp.MustCompile(`^\d+\.?\d*[hdmw]$`)

var attributeWords = map[string]bool{
	"step": true, "steps": true, "event": true, "fold": true,
	"xs": true, "sm": true, "md": true, "lg": true, "xl": true,
	"2xl": true, "3xl": true, "4xl": true, "5xl": true,
	"epic": true, "legendary": true, "mythic": true, "ultimate": true,
}

// IsAttributeWord: a bare @word that is an attribute, not a tag: a duration
// (@2h), priority or importance (@p1, @i2), a size (@sm), @step(s), @event,
// @fold. As the plugin's link_index shortcut.
func IsAttributeWord(key string) bool {
	if attributeWords[key] || durationWord.MatchString(key) {
		return true
	}
	return len(key) == 2 && (key[0] == 'p' || key[0] == 'i') && key[1] >= '1' && key[1] <= '3'
}
