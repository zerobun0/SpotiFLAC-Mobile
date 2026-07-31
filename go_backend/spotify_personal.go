// go_backend/spotify_personal.go
package gobackend

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base32"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Read the CURRENT values from extensions/spotify-web.sflx's index.js
// (TOTP_SECRETS[TOTP_VERSION], TOTP_VERSION) before relying on this — Spotify
// rotates this anti-bot secret table periodically and the bundled extension
// is kept up to date with it independently of this file.
var spotifyTOTPSecretTable = []int{44, 55, 47, 42, 70, 40, 34, 114, 76, 74, 50, 111, 120, 97, 75, 76, 94, 102, 43, 69, 49, 120, 118, 80, 64, 78}

const spotifyTOTPVersion = 61

const spotifyPartnerAPIURL = "https://api-partner.spotify.com/pathfinder/v2/query"
const spotifyClientTokenURL = "https://clienttoken.spotify.com/v1/clienttoken"
const spotifyHomeFeedSHA256Hash = "3a67ee0ea6abad2ebad2e588a9aa130fc98d6b553f5b05ac6467503d02133bdc"

type spotifyPersonalSession struct {
	accessToken   string
	clientToken   string
	clientID      string
	clientVersion string
	cookies       map[string]string
}

func generateSpotifyTOTP() string {
	transformed := make([]byte, len(spotifyTOTPSecretTable))
	for i, b := range spotifyTOTPSecretTable {
		transformed[i] = byte(b ^ ((i % 33) + 9))
	}
	var joined strings.Builder
	for _, b := range transformed {
		joined.WriteString(strconv.Itoa(int(b)))
	}
	var hexBytes bytes.Buffer
	for _, r := range joined.String() {
		hexBytes.WriteByte(byte(r))
	}
	secret := base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(hexBytes.Bytes())

	counter := uint64(time.Now().Unix() / 30)
	counterBytes := make([]byte, 8)
	binary.BigEndian.PutUint64(counterBytes, counter)

	key, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(strings.ToUpper(secret))
	if err != nil {
		return "000000"
	}
	mac := hmac.New(sha1.New, key)
	mac.Write(counterBytes)
	sum := mac.Sum(nil)
	offset := sum[len(sum)-1] & 0x0f
	code := (uint32(sum[offset]&0x7f) << 24) |
		(uint32(sum[offset+1]) << 16) |
		(uint32(sum[offset+2]) << 8) |
		uint32(sum[offset+3])
	otp := code % 1000000
	return fmt.Sprintf("%06d", otp)
}

func buildSpotifyCookieHeader(cookies map[string]string) string {
	parts := make([]string, 0, len(cookies))
	for name, value := range cookies {
		parts = append(parts, name+"="+value)
	}
	return strings.Join(parts, "; ")
}

var spotifyAppServerConfigPattern = regexp.MustCompile(`<script id="appServerConfig" type="text/plain">([^<]+)</script>`)

func bootstrapSpotifyPersonalSession(ctx context.Context, client *http.Client, sessionCookie string) (*spotifyPersonalSession, error) {
	session := &spotifyPersonalSession{cookies: map[string]string{"sp_dc": sessionCookie}}

	// Step 1: GET open.spotify.com with the real session cookie attached to
	// seed additional session cookies and read the current clientVersion.
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://open.spotify.com", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Cookie", buildSpotifyCookieHeader(session.cookies))
	req.Header.Set("User-Agent", "Mozilla/5.0 (Linux; Android 14) SpotiFLAC")
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to load open.spotify.com: %w", err)
	}
	body, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("open.spotify.com returned %d", resp.StatusCode)
	}
	mergeSpotifySetCookies(session.cookies, resp.Header.Values("Set-Cookie"))
	if match := spotifyAppServerConfigPattern.FindSubmatch(body); match != nil {
		// The appServerConfig script body is base64-encoded (the real Spotify
		// web player decodes it with atob() before JSON-parsing it) — decode
		// it the same way here rather than JSON-parsing the raw base64 text.
		if decoded, decErr := base64.StdEncoding.DecodeString(strings.TrimSpace(string(match[1]))); decErr == nil {
			var cfg struct {
				ClientVersion string `json:"clientVersion"`
			}
			if err := json.Unmarshal(decoded, &cfg); err == nil {
				session.clientVersion = cfg.ClientVersion
			}
		}
	}
	if session.clientVersion == "" {
		return nil, fmt.Errorf("failed to read clientVersion from open.spotify.com response")
	}

	// Step 2: GET the access-token endpoint with the same cookies attached —
	// with a real sp_dc cookie present, this returns a real user's access
	// token instead of an anonymous one.
	totp := generateSpotifyTOTP()
	tokenURL := fmt.Sprintf(
		"https://open.spotify.com/api/token?reason=init&productType=web-player&totp=%s&totpVer=%d&totpServer=%s",
		totp, spotifyTOTPVersion, totp,
	)
	req, err = http.NewRequestWithContext(ctx, http.MethodGet, tokenURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Cookie", buildSpotifyCookieHeader(session.cookies))
	req.Header.Set("User-Agent", "Mozilla/5.0 (Linux; Android 14) SpotiFLAC")
	resp, err = client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch access token: %w", err)
	}
	body, err = io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("access token request returned %d", resp.StatusCode)
	}
	mergeSpotifySetCookies(session.cookies, resp.Header.Values("Set-Cookie"))

	var tokenResp struct {
		AccessToken string `json:"accessToken"`
		ClientID    string `json:"clientId"`
		IsAnonymous bool   `json:"isAnonymous"`
	}
	if err := json.Unmarshal(body, &tokenResp); err != nil {
		return nil, fmt.Errorf("failed to parse access token response: %w", err)
	}
	if tokenResp.AccessToken == "" {
		return nil, fmt.Errorf("empty access token in response")
	}
	if tokenResp.IsAnonymous {
		return nil, fmt.Errorf("session cookie did not yield an authenticated session — it may have expired; please log in again")
	}
	session.accessToken = tokenResp.AccessToken
	session.clientID = tokenResp.ClientID

	// Step 3: bootstrap the client token (identity-agnostic — same call an
	// anonymous visitor makes).
	clientTokenPayload := map[string]any{
		"client_data": map[string]any{
			"client_version": session.clientVersion,
			"client_id":      session.clientID,
			"js_sdk_data": map[string]any{
				"device_brand": "unknown",
				"device_model": "unknown",
				"os":           "android",
				"os_version":   "14",
				"device_id":    session.cookies["sp_t"],
				"device_type":  "smartphone",
			},
		},
	}
	payloadBytes, err := json.Marshal(clientTokenPayload)
	if err != nil {
		return nil, err
	}
	req, err = http.NewRequestWithContext(ctx, http.MethodPost, spotifyClientTokenURL, bytes.NewReader(payloadBytes))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "Mozilla/5.0 (Linux; Android 14) SpotiFLAC")
	resp, err = client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch client token: %w", err)
	}
	body, err = io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("client token request returned %d", resp.StatusCode)
	}
	var clientTokenResp struct {
		ResponseType string `json:"response_type"`
		GrantedToken struct {
			Token string `json:"token"`
		} `json:"granted_token"`
	}
	if err := json.Unmarshal(body, &clientTokenResp); err != nil {
		return nil, fmt.Errorf("failed to parse client token response: %w", err)
	}
	if clientTokenResp.ResponseType != "RESPONSE_GRANTED_TOKEN_RESPONSE" {
		return nil, fmt.Errorf("unexpected client token response: %s", clientTokenResp.ResponseType)
	}
	session.clientToken = clientTokenResp.GrantedToken.Token

	return session, nil
}

func mergeSpotifySetCookies(cookies map[string]string, setCookieHeaders []string) {
	for _, header := range setCookieHeaders {
		firstPair := strings.SplitN(header, ";", 2)[0]
		nameValue := strings.SplitN(firstPair, "=", 2)
		if len(nameValue) != 2 {
			continue
		}
		cookies[strings.TrimSpace(nameValue[0])] = strings.TrimSpace(nameValue[1])
	}
}

func fetchSpotifyHomeFeed(ctx context.Context, client *http.Client, session *spotifyPersonalSession) (map[string]any, error) {
	payload := map[string]any{
		"operationName": "home",
		"variables":     map[string]any{"timeZone": "UTC"},
		"extensions": map[string]any{
			"persistedQuery": map[string]any{
				"version":    1,
				"sha256Hash": spotifyHomeFeedSHA256Hash,
			},
		},
	}
	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, spotifyPartnerAPIURL, bytes.NewReader(payloadBytes))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+session.accessToken)
	req.Header.Set("Client-Token", session.clientToken)
	req.Header.Set("Spotify-App-Version", session.clientVersion)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "Mozilla/5.0 (Linux; Android 14) SpotiFLAC")

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("home feed query failed: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("home feed query returned %d: %s", resp.StatusCode, string(body))
	}
	var parsed map[string]any
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil, fmt.Errorf("failed to parse home feed response: %w", err)
	}
	return parsed, nil
}

// getNestedSpotifyValue walks a dot-separated path through decoded JSON,
// where each segment is either a map key (e.g. "albumOfTrack") or, when the
// current value is a slice, a numeric index (e.g. the "0" in
// "sources.0.url" — JSON arrays decode to []any, so an all-map-only walker
// would silently return nil the moment a path crosses an array boundary).
func getNestedSpotifyValue(data map[string]any, path string) any {
	current := any(data)
	for _, key := range strings.Split(path, ".") {
		switch v := current.(type) {
		case map[string]any:
			current = v[key]
		case []any:
			index, err := strconv.Atoi(key)
			if err != nil || index < 0 || index >= len(v) {
				return nil
			}
			current = v[index]
		default:
			return nil
		}
	}
	return current
}

// formatSpotifyHomeFeedResponse normalizes the raw partner-API "home" query
// response into this app's ExploreSection/ExploreItem JSON shape (matching
// lib/providers/explore_provider.dart's ExploreSection.fromJson /
// ExploreItem.fromJson). Field paths mirror the bundled spotify-web
// extension's formatHomeFeedData — same public GraphQL response shape,
// independently re-derived here in Go rather than copied.
func formatSpotifyHomeFeedResponse(raw map[string]any) map[string]any {
	home, _ := getNestedSpotifyValue(raw, "data.home").(map[string]any)
	greeting, _ := getNestedSpotifyValue(home, "greeting.text").(string)

	sectionContainer, _ := home["sectionContainer"].(map[string]any)
	sectionsRaw, _ := getNestedSpotifyValue(sectionContainer, "sections.items").([]any)

	sections := make([]map[string]any, 0, len(sectionsRaw))
	for _, rawSection := range sectionsRaw {
		section, ok := rawSection.(map[string]any)
		if !ok {
			continue
		}
		sectionData, _ := section["data"].(map[string]any)
		title, _ := getNestedSpotifyValue(sectionData, "title.text").(string)
		if title == "" {
			continue
		}
		sectionURI, _ := section["uri"].(string)

		itemsRaw, _ := getNestedSpotifyValue(section, "sectionItems.items").([]any)
		items := make([]map[string]any, 0, len(itemsRaw))
		for _, rawItem := range itemsRaw {
			item, ok := formatSpotifyHomeFeedItem(rawItem)
			if ok {
				items = append(items, item)
			}
		}
		if len(items) == 0 {
			continue
		}
		sections = append(sections, map[string]any{
			"uri":   sectionURI,
			"title": title,
			"items": items,
		})
	}

	return map[string]any{
		"success":  true,
		"greeting": greeting,
		"sections": sections,
	}
}

func formatSpotifyHomeFeedItem(rawItem any) (map[string]any, bool) {
	itemMap, ok := rawItem.(map[string]any)
	if !ok {
		return nil, false
	}
	contentData, _ := getNestedSpotifyValue(itemMap, "content.data").(map[string]any)
	uri, _ := contentData["uri"].(string)
	if uri == "" {
		return nil, false
	}
	uriParts := strings.Split(uri, ":")
	if len(uriParts) < 3 {
		return nil, false
	}
	itemType := uriParts[1]
	itemID := uriParts[2]

	name, _ := contentData["name"].(string)
	if name == "" {
		name, _ = getNestedSpotifyValue(contentData, "profile.name").(string)
	}

	var coverURL, artistNames, description, albumID, albumName string
	var durationMs float64

	switch itemType {
	case "track":
		coverURL, _ = getNestedSpotifyValue(contentData, "albumOfTrack.coverArt.sources.0.url").(string)
		if d, ok := getNestedSpotifyValue(contentData, "duration.totalMilliseconds").(float64); ok {
			durationMs = d
		} else if d, ok := getNestedSpotifyValue(contentData, "trackDuration.totalMilliseconds").(float64); ok {
			// Reference index.js:1892-1893 falls back to trackDuration when
			// duration is absent — some track shapes use the other field name.
			durationMs = d
		}
		if albumURI, ok := getNestedSpotifyValue(contentData, "albumOfTrack.uri").(string); ok {
			albumParts := strings.Split(albumURI, ":")
			if len(albumParts) >= 3 {
				albumID = albumParts[2]
			}
		}
		albumName, _ = getNestedSpotifyValue(contentData, "albumOfTrack.name").(string)
		artistItems, _ := getNestedSpotifyValue(contentData, "artists.items").([]any)
		if len(artistItems) == 0 {
			// Reference index.js:1903-1912 falls back to firstArtist/otherArtists
			// when artists.items is empty — some track shapes represent artists
			// this way instead.
			if firstArtist, ok := getNestedSpotifyValue(contentData, "firstArtist.items.0.profile.name").(string); ok && firstArtist != "" {
				artistNames = firstArtist
				if otherArtists, ok := getNestedSpotifyValue(contentData, "otherArtists.items").([]any); ok {
					for _, rawOther := range otherArtists {
						otherMap, ok := rawOther.(map[string]any)
						if !ok {
							continue
						}
						if oName, ok := getNestedSpotifyValue(otherMap, "profile.name").(string); ok && oName != "" {
							artistNames += ", " + oName
						}
					}
				}
			}
		} else {
			artistNames = joinSpotifyArtistNames(artistItems)
		}
	case "album":
		coverURL, _ = getNestedSpotifyValue(contentData, "coverArt.sources.0.url").(string)
		artistItems, _ := getNestedSpotifyValue(contentData, "artists.items").([]any)
		if len(artistItems) == 0 {
			// Reference index.js:1921-1925 falls back to artists.0.name, then
			// artist.name, when artists.items is empty.
			artistName, ok := getNestedSpotifyValue(contentData, "artists.0.name").(string)
			if !ok || artistName == "" {
				artistName, _ = getNestedSpotifyValue(contentData, "artist.name").(string)
			}
			artistNames = artistName
		} else {
			artistNames = joinSpotifyAlbumArtistNames(artistItems)
		}
	case "playlist":
		coverURL, _ = getNestedSpotifyValue(contentData, "images.items.0.sources.0.url").(string)
		description, _ = contentData["description"].(string)
		artistNames, _ = getNestedSpotifyValue(contentData, "ownerV2.data.name").(string)
	case "artist":
		coverURL, _ = getNestedSpotifyValue(contentData, "visuals.avatarImage.sources.0.url").(string)
	case "station":
		coverURL, _ = getNestedSpotifyValue(contentData, "image.sources.0.url").(string)
	default:
		// Reference index.js:1890-1939 has no else branch for unhandled types —
		// items of any other type (e.g. episode, show, audiobook) still get
		// emitted with id/uri/type/name populated and cover/artists/etc. left
		// at their zero values, rather than being dropped. Dropping them here
		// would silently empty out — and hide — whole sections like "Your
		// shows" via the len(items) == 0 guard in the caller.
	}

	return map[string]any{
		"id":          itemID,
		"uri":         uri,
		"type":        itemType,
		"name":        name,
		"artists":     artistNames,
		"description": description,
		"cover_url":   coverURL,
		"album_id":    albumID,
		"album_name":  albumName,
		"duration_ms": int(durationMs),
		"provider_id": "spotify-personal",
	}, true
}

func joinSpotifyArtistNames(rawItems any) string {
	items, ok := rawItems.([]any)
	if !ok {
		return ""
	}
	names := make([]string, 0, len(items))
	for _, rawItem := range items {
		itemMap, ok := rawItem.(map[string]any)
		if !ok {
			continue
		}
		if name, ok := getNestedSpotifyValue(itemMap, "profile.name").(string); ok && name != "" {
			names = append(names, name)
		}
	}
	return strings.Join(names, ", ")
}

// joinSpotifyAlbumArtistNames mirrors the reference's album artist-items
// mapping (index.js:1928-1930), which additionally falls back to a direct
// "name" property when "profile.name" is absent — unlike the track path,
// which only ever reads "profile.name".
func joinSpotifyAlbumArtistNames(rawItems any) string {
	items, ok := rawItems.([]any)
	if !ok {
		return ""
	}
	names := make([]string, 0, len(items))
	for _, rawItem := range items {
		itemMap, ok := rawItem.(map[string]any)
		if !ok {
			continue
		}
		name, ok := getNestedSpotifyValue(itemMap, "profile.name").(string)
		if !ok || name == "" {
			name, _ = itemMap["name"].(string)
		}
		if name != "" {
			names = append(names, name)
		}
	}
	return strings.Join(names, ", ")
}
