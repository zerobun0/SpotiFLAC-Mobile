// go_backend/spotify_personal_test.go
package gobackend

import (
	"encoding/json"
	"testing"
)

func TestFormatSpotifyHomeFeedResponse(t *testing.T) {
	raw := []byte(`{
		"data": {
			"home": {
				"greeting": {"text": "Good evening"},
				"sectionContainer": {
					"sections": {
						"items": [
							{
								"uri": "section:1",
								"data": {"title": {"text": "Made for you"}},
								"sectionItems": {
									"items": [
										{
											"content": {
												"data": {
													"__typename": "Track",
													"uri": "spotify:track:abc123",
													"name": "Song Name",
													"albumOfTrack": {
														"name": "Album Name",
														"uri": "spotify:album:def456",
														"coverArt": {"sources": [{"url": "https://img/1.jpg"}]}
													},
													"artists": {"items": [{"profile": {"name": "Artist A"}}]},
													"duration": {"totalMilliseconds": 210000}
												}
											}
										}
									]
								}
							}
						]
					}
				}
			}
		}
	}`)

	var parsed map[string]any
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Fatalf("failed to parse fixture: %v", err)
	}

	result := formatSpotifyHomeFeedResponse(parsed)

	if result["greeting"] != "Good evening" {
		t.Fatalf("expected greeting %q, got %v", "Good evening", result["greeting"])
	}
	sections, ok := result["sections"].([]map[string]any)
	if !ok || len(sections) != 1 {
		t.Fatalf("expected 1 section, got %v", result["sections"])
	}
	items, ok := sections[0]["items"].([]map[string]any)
	if !ok || len(items) != 1 {
		t.Fatalf("expected 1 item, got %v", sections[0]["items"])
	}
	item := items[0]
	if item["id"] != "abc123" || item["type"] != "track" {
		t.Fatalf("unexpected item id/type: %v/%v", item["id"], item["type"])
	}
	if item["name"] != "Song Name" || item["artists"] != "Artist A" {
		t.Fatalf("unexpected item name/artists: %v/%v", item["name"], item["artists"])
	}
	if item["album_name"] != "Album Name" || item["album_id"] != "def456" {
		t.Fatalf("unexpected album fields: %v/%v", item["album_name"], item["album_id"])
	}
	if item["cover_url"] != "https://img/1.jpg" {
		t.Fatalf("unexpected cover_url: %v", item["cover_url"])
	}
	if item["duration_ms"] != 210000 {
		t.Fatalf("unexpected duration_ms: %v", item["duration_ms"])
	}
	if item["provider_id"] != "spotify-personal" {
		t.Fatalf("expected provider_id spotify-personal, got %v", item["provider_id"])
	}
}
