package main

import (
	"regexp"
	"sort"
	"strings"
)

// ==========================================================
// NORYTH - CASE #001 SERVER SQL VALIDATOR
//
// Subset SQL read-only untuk latihan investigasi.
// Tidak menjalankan SQL mentah dari pengguna.
// ==========================================================

type SQLLog struct {
	Username  string
	Aktivitas string
}

var case001Evidence = []SQLLog{
	{"admin", "login"},
	{"raka_07", "akses_root"},
	{"dina_02", "login"},
	{"raka_07", "akses_root"},
	{"budi_01", "logout"},
	{"raka_07", "akses_root"},
	{"dina_02", "akses_root"},
}

type SQLValidationResult struct {
	Correct bool
	Valid   bool
	Rows    map[string]int
}

var sqlComments = regexp.MustCompile(`--[^\r\n]*`)
var sqlWhitespace = regexp.MustCompile(`\s+`)

var sqlSelectPattern = regexp.MustCompile(
	`^select\s+(.+?)\s+from\s+([a-z_][a-z0-9_]*)` +
		`(?:\s+where\s+(.+?))?` +
		`(?:\s+group\s+by\s+(.+?))?` +
		`(?:\s+order\s+by\s+(.+))?$`,
)

var sqlUsernamePattern = regexp.MustCompile(
	`^username(?:\s+(?:as\s+)?[a-z_][a-z0-9_]*)?$`,
)

var sqlCountPattern = regexp.MustCompile(
	`^count\s*\(\s*(?:\*|1)\s*\)` +
		`(?:\s+(?:as\s+)?([a-z_][a-z0-9_]*))?$`,
)

var sqlWherePattern = regexp.MustCompile(
	`^aktivitas\s*=\s*['"]([a-z_][a-z0-9_]*)['"]$`,
)

var sqlWhereReversedPattern = regexp.MustCompile(
	`^['"]([a-z_][a-z0-9_]*)['"]\s*=\s*aktivitas$`,
)

var sqlOrderPattern = regexp.MustCompile(
	`^([a-z_][a-z0-9_]*|count\s*\(\s*(?:\*|1)\s*\))` +
		`(?:\s+(asc|desc))?$`,
)

func normalizeCase001SQL(query string) string {
	query = strings.NewReplacer(
		"‘", "'",
		"’", "'",
		"“", `"`,
		"”", `"`,
		"\u00a0", " ",
		"\u200b", "",
		"\u200c", "",
		"\u200d", "",
		"\ufeff", "",
	).Replace(query)

	query = sqlComments.ReplaceAllString(query, " ")
	query = sqlWhitespace.ReplaceAllString(query, " ")

	return strings.ToLower(strings.TrimSpace(query))
}

func validateCase001SQL(query string) SQLValidationResult {
	failed := SQLValidationResult{
		Correct: false,
		Valid:   false,
		Rows:    map[string]int{},
	}

	if len(query) == 0 || len(query) > 4000 {
		return failed
	}

	sql := normalizeCase001SQL(query)
	sql = strings.TrimSpace(strings.TrimSuffix(sql, ";"))

	// Hanya satu SELECT read-only.
	if strings.Contains(sql, ";") ||
		!strings.HasPrefix(sql, "select ") {
		return failed
	}

	parsed := sqlSelectPattern.FindStringSubmatch(sql)
	if parsed == nil {
		return failed
	}

	selectPart := strings.TrimSpace(parsed[1])
	table := strings.TrimSpace(parsed[2])
	where := strings.TrimSpace(parsed[3])
	group := strings.TrimSpace(parsed[4])
	order := strings.TrimSpace(parsed[5])

	if table != "server_logs" ||
		where == "" ||
		group != "username" {
		return failed
	}

	// SELECT harus mempunyai username dan COUNT.
	columns := strings.Split(selectPart, ",")
	if len(columns) != 2 {
		return failed
	}

	usernameCount := 0
	countCount := 0
	countAlias := ""

	for _, column := range columns {
		column = strings.TrimSpace(column)

		if sqlUsernamePattern.MatchString(column) {
			usernameCount++
			continue
		}

		if match := sqlCountPattern.FindStringSubmatch(column); match != nil {
			countCount++
			countAlias = match[1]
			continue
		}

		return failed
	}

	if usernameCount != 1 || countCount != 1 {
		return failed
	}

	// Validasi WHERE.
	filterValue := ""

	if match := sqlWherePattern.FindStringSubmatch(where); match != nil {
		filterValue = match[1]
	} else if match := sqlWhereReversedPattern.FindStringSubmatch(where); match != nil {
		filterValue = match[1]
	} else {
		return failed
	}

	// ORDER BY opsional.
	if order != "" {
		match := sqlOrderPattern.FindStringSubmatch(order)
		if match == nil {
			return failed
		}

		field := sqlWhitespace.ReplaceAllString(match[1], "")

		allowed := map[string]bool{
			"username": true,
			"count(*)": true,
			"count(1)": true,
		}
		if countAlias != "" {
			allowed[countAlias] = true
		}

		if !allowed[field] {
			return failed
		}
	}

	actual := map[string]int{}
	expected := map[string]int{}

	for _, entry := range case001Evidence {
		if entry.Aktivitas == filterValue {
			actual[entry.Username]++
		}

		if entry.Aktivitas == "akses_root" {
			expected[entry.Username]++
		}
	}

	matches := len(actual) == len(expected)

	if matches {
		for username, count := range expected {
			if actual[username] != count {
				matches = false
				break
			}
		}
	}

	return SQLValidationResult{
		Correct: matches,
		Valid:   true,
		Rows:    actual,
	}
}

// Fungsi untuk mendapatkan urutan nama akun yang
// terdeteksi. Berguna untuk pengujian.
func sortedCase001Users(rows map[string]int) []string {
	names := make([]string, 0, len(rows))

	for name := range rows {
		names = append(names, name)
	}

	sort.Strings(names)
	return names
}
