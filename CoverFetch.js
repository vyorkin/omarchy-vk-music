// What a cover asks for, and which answers are not worth asking again.
//
// VK keeps handing out the URL of a cover it has already deleted: a scan of 83 covers
// fetched in the same minute as their payload found two answering 404, and the CDN also
// answers 424 or resets the stream now and then. A tile that asked again every time a
// gallery was reopened wrote the same failure into the shell log forty times in one
// boot, and each ask cost a request that could only fail.
//
// So a source that fails twice — its own ask and one retry, which lets a hiccup recover —
// is remembered here for the life of the shell and drawn as the monogram straight away.
// A source is the whole URL, signatures included, so two entries never mean one picture.
//
// The retry carries a nonce because Qt caches a failed image under its URL: the same
// string would never reach the network a second time.
.pragma library

var dead = Object.create(null)

// A source that failed its retry: the tile shows the tint from now on.
function known(source) {
  return source !== "" && dead[source] === true
}

function mark(source) {
  if (source !== "") dead[source] = true
}

// The URL to ask for: nothing while the source is known to be dead, the source itself on
// the first attempt, and the same source with a nonce after that. The attempt is negative
// once the tile has given up, which is also `known` if another tile was the one to fail.
//
// A nonce is only added to a remote URL: appending it to a local path would name a file
// that does not exist, and Qt would be asked for a picture twice for no reason.
function request(source, attempt) {
  if (source === "" || attempt < 0 || known(source)) return ""
  if (attempt < 1 || source.indexOf("://") < 0) return source
  return source + (source.indexOf("?") >= 0 ? "&" : "?") + "omarchyRetry=" + attempt
}
