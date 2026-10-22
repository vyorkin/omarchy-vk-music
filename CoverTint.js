// What a cover-less playlist looks like: a tint and a monogram, both taken from its
// own title.
//
// The tint has to be the same on every open and on every machine, so it is a hash of
// the title rather than a counter or a random pick; and it has to be quiet enough to
// sit beside real covers, so only the hue comes from the hash. The colour itself is
// mixed by the caller into the theme's own popup surface, which keeps the tile dark in
// a dark theme and pale in a light one without a second palette to maintain.
.pragma library

// 0..359. Small, stable, and spread well enough for a screen of thirty cards.
function hue(text) {
  var value = 0
  var source = String(text || "")
  for (var i = 0; i < source.length; i++) value = (value * 31 + source.charCodeAt(i)) % 100003
  return value % 360
}

// The first letters of the first two words that are not punctuation or a short
// preposition: «Блюз: Краткая история» reads «БК», the way a contact avatar
// abbreviates a name. One word gives one letter — «Сын» is «С», not «СЫ».
var SKIP = [
  "от", "до", "и", "в", "во", "на", "по", "за", "из", "для", "с", "со", "к", "ко",
  "о", "об", "у", "а", "но", "не", "или",
  "the", "of", "and", "to", "in", "on", "for", "a", "an", "de", "da", "la", "le"
]
var WORD_BREAKS = /[«»“”„‘’'"`()\[\]{}:;,./\\|—–\-_+*&!?#@~<>]/g

function monogram(text) {
  var words = String(text || "").replace(WORD_BREAKS, " ").split(/\s+/)
  var letters = ""
  for (var i = 0; i < words.length && letters.length < 2; i++) {
    var word = words[i]
    if (word.length < 2 || SKIP.indexOf(word.toLowerCase()) !== -1) continue
    letters += word.charAt(0).toUpperCase()
  }
  return letters
}
