module memscan-leaderboard

go 1.22

// Direct dependencies. Run `go mod tidy` once to fetch these and pin the (many) indirect
// modernc.org/* deps into go.sum - they are not listed here on purpose (tidy generates them).
require (
	golang.org/x/time v0.5.0
	modernc.org/sqlite v1.34.1
)
