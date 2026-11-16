package main

import "testing"

// ==========================================================
// NORYTH - LEVEL & RANK TEST
// ==========================================================

func TestCalculateNorythLevel(t *testing.T) {
	tests := []struct {
		xp    int64
		level int64
		rank  string
	}{
		{0, 1, "Rekrut"},
		{150, 1, "Rekrut"},
		{199, 1, "Rekrut"},
		{200, 2, "Rekrut"},
		{350, 2, "Rekrut"},
		{499, 2, "Rekrut"},
		{500, 3, "Analis Digital"},
		{1400, 5, "Investigator"},
		{3500, 8, "Senior Investigator"},
		{6500, 11, "Master Detective"},
	}

	for _, tt := range tests {
		got := calculateNorythLevel(tt.xp)

		if got.Level != tt.level {
			t.Errorf(
				"XP %d: level %d, expected %d",
				tt.xp,
				got.Level,
				tt.level,
			)
		}

		if got.Rank != tt.rank {
			t.Errorf(
				"XP %d: rank %s, expected %s",
				tt.xp,
				got.Rank,
				tt.rank,
			)
		}
	}
}

// ==========================================================
// NORYTH - JAVASCRIPT VALIDATION TEST
// ==========================================================

func TestValidJavaScriptAnswer(t *testing.T) {
	tests := []struct {
		name     string
		code     string
		expected bool
	}{
		{
			name: "Jawaban benar",
			code: `const hasil = logs.filter(log =>
				log.riskScore >= 80 &&
				log.action === "deleted"
			);
			console.log(hasil);`,
			expected: true,
		},
		{
			name: "Nama variabel berbeda",
			code: `logs.filter(item =>
				item.riskScore >= 80 &&
				item.action === 'deleted'
			)`,
			expected: true,
		},
		{
			name: "Hanya riskScore",
			code: `logs.filter(log =>
				log.riskScore >= 80
			)`,
			expected: false,
		},
		{
			name: "Hanya action",
			code: `logs.filter(log =>
				log.action === "deleted"
			)`,
			expected: false,
		},
		{
			name:     "Editor kosong",
			code:     "",
			expected: false,
		},
		{
			name:     "Kode tidak valid",
			code:     `alert("hello")`,
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			actual := validJavaScriptAnswer(tt.code)

			if actual != tt.expected {
				t.Errorf(
					"expected %v, got %v",
					tt.expected,
					actual,
				)
			}
		})
	}
}
