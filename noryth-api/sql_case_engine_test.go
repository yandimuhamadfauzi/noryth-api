package main

import "testing"

func TestValidateCase001SQL(t *testing.T) {
	tests := []struct {
		name    string
		query   string
		correct bool
		valid   bool
	}{
		{
			name: "Jawaban benar",
			query: `SELECT username, COUNT(*)
				FROM server_logs
				WHERE aktivitas = 'akses_root'
				GROUP BY username;`,
			correct: true,
			valid:   true,
		},
		{
			name: "Jawaban dengan alias",
			query: `SELECT username, COUNT(*) AS jumlah
				FROM server_logs
				WHERE aktivitas = 'akses_root'
				GROUP BY username
				ORDER BY jumlah DESC;`,
			correct: true,
			valid:   true,
		},
		{
			name: "COUNT 1 juga diterima",
			query: `SELECT COUNT(1), username
				FROM server_logs
				WHERE aktivitas = 'akses_root'
				GROUP BY username;`,
			correct: true,
			valid:   true,
		},
		{
			name: "Filter salah",
			query: `SELECT username, COUNT(*)
				FROM server_logs
				WHERE aktivitas = 'login'
				GROUP BY username;`,
			correct: false,
			valid:   true,
		},
		{
			name:    "Query kosong",
			query:   "",
			correct: false,
			valid:   false,
		},
		{
			name:    "Perintah DELETE ditolak",
			query:   "DELETE FROM server_logs;",
			correct: false,
			valid:   false,
		},
		{
			name: "Query ganda ditolak",
			query: `SELECT username, COUNT(*)
				FROM server_logs
				WHERE aktivitas = 'akses_root'
				GROUP BY username;
				DELETE FROM server_logs;`,
			correct: false,
			valid:   false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := validateCase001SQL(tt.query)

			if result.Correct != tt.correct {
				t.Errorf(
					"Correct: expected %v, got %v",
					tt.correct,
					result.Correct,
				)
			}

			if result.Valid != tt.valid {
				t.Errorf(
					"Valid: expected %v, got %v",
					tt.valid,
					result.Valid,
				)
			}
		})
	}
}

func TestCase001Evidence(t *testing.T) {
	result := validateCase001SQL(
		`SELECT username, COUNT(*)
		FROM server_logs
		WHERE aktivitas = 'akses_root'
		GROUP BY username;`,
	)

	if !result.Correct {
		t.Fatal("Jawaban seharusnya benar")
	}

	if result.Rows["raka_07"] != 3 {
		t.Error("raka_07 harus memiliki 3 akses root")
	}

	if result.Rows["dina_02"] != 1 {
		t.Error("dina_02 harus memiliki 1 akses root")
	}

	if len(result.Rows) != 2 {
		t.Error("Hanya dua akun yang terdeteksi")
	}
}
