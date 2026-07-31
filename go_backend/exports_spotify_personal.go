// go_backend/exports_spotify_personal.go
package gobackend

import (
	"context"
	"net/http"
	"time"
)

// GetSpotifyPersonalHomeFeed fetches the real, logged-in-user personalized
// Spotify home feed using a session cookie captured by the app's WebView
// login screen (see spotify_web_login_screen.dart). Returns a JSON string
// shaped like the existing extension home-feed contract
// ({"success","error","greeting","sections"}) so it plugs into the exact
// same Dart-side parsing explore_provider.dart already has for extension
// home feeds.
func GetSpotifyPersonalHomeFeed(sessionCookie string) (string, error) {
	if sessionCookie == "" {
		return marshalJSONString(map[string]any{
			"success": false,
			"error":   "no Spotify session cookie available; please log in again",
		})
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	client := &http.Client{Timeout: 20 * time.Second}
	session, err := bootstrapSpotifyPersonalSession(ctx, client, sessionCookie)
	if err != nil {
		return marshalJSONString(map[string]any{
			"success": false,
			"error":   err.Error(),
		})
	}

	raw, err := fetchSpotifyHomeFeed(ctx, client, session)
	if err != nil {
		return marshalJSONString(map[string]any{
			"success": false,
			"error":   err.Error(),
		})
	}

	return marshalJSONString(formatSpotifyHomeFeedResponse(raw))
}
