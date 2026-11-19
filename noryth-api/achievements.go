package main

import (
	"context"
	"fmt"
	"log"
	"net/http"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type AchievementDefinition struct {
	ID          string
	Name        string
	Description string
}

type AchievementSyncResponse struct {
	Success  bool     `json:"success"`
	Unlocked []string `json:"unlocked"`
	Total    int      `json:"total"`
	Message  string   `json:"message"`
}

var achievementDefinitions = []AchievementDefinition{
	{
		ID:          "code_breaker",
		Name:        "Pemecah Kode",
		Description: "Menyelesaikan Kasus #001 SQL",
	},
	{
		ID:          "pattern_hunter",
		Name:        "Pemburu Pola",
		Description: "Menyelesaikan Kasus #002 JavaScript",
	},
	{
		ID:          "forensic_analyst",
		Name:        "Analis Forensik",
		Description: "Menyelesaikan Kasus #003 Python",
	},
	{
		ID:          "master_investigator",
		Name:        "Master Investigator",
		Description: "Menyelesaikan ketiga kasus investigasi",
	},
}

func (s *Server) syncAchievements(
	ctx context.Context,
	uid string,
) (AchievementSyncResponse, error) {
	userRef := s.db.Collection("users").Doc(uid)
	practice := userRef.Collection("missionPractice")
	achievements := userRef.Collection("achievements")

	response := AchievementSyncResponse{
		Success:  true,
		Unlocked: []string{},
	}

	err := s.db.RunTransaction(
		ctx,
		func(ctx context.Context, tx *firestore.Transaction) error {
			caseIDs := []string{
				"case_001",
				"case_002",
				"case_003",
			}

			completed := make(map[string]bool, len(caseIDs))

			for _, caseID := range caseIDs {
				snap, err := tx.Get(practice.Doc(caseID))

				if err != nil {
					if status.Code(err) == codes.NotFound {
						completed[caseID] = false
						continue
					}

					return fmt.Errorf(
						"gagal membaca %s: %w",
						caseID,
						err,
					)
				}

				completed[caseID] = boolValue(
					snap.Data()["practiceCompleted"],
				)
			}

			eligible := map[string]bool{
				"code_breaker":     completed["case_001"],
				"pattern_hunter":   completed["case_002"],
				"forensic_analyst": completed["case_003"],
				"master_investigator": completed["case_001"] &&
					completed["case_002"] &&
					completed["case_003"],
			}

			// Semua dokumen badge dibaca sebelum transaksi menulis.
			exists := make(map[string]bool, len(achievementDefinitions))

			for _, badge := range achievementDefinitions {
				snap, err := tx.Get(achievements.Doc(badge.ID))

				if err != nil {
					if status.Code(err) == codes.NotFound {
						exists[badge.ID] = false
						continue
					}

					return fmt.Errorf(
						"gagal membaca badge %s: %w",
						badge.ID,
						err,
					)
				}

				exists[badge.ID] = snap.Exists()
			}

			unlocked := make([]string, 0, len(achievementDefinitions))
			total := 0

			for _, badge := range achievementDefinitions {
				if exists[badge.ID] {
					total++
					continue
				}

				if !eligible[badge.ID] {
					continue
				}

				ref := achievements.Doc(badge.ID)

				data := map[string]interface{}{
					"id":          badge.ID,
					"name":        badge.Name,
					"description": badge.Description,
					"unlocked":    true,
					"unlockedAt":  firestore.ServerTimestamp,
				}

				if err := tx.Set(ref, data); err != nil {
					return fmt.Errorf(
						"gagal menyimpan badge %s: %w",
						badge.ID,
						err,
					)
				}

				unlocked = append(unlocked, badge.ID)
				total++
			}

			response = AchievementSyncResponse{
				Success:  true,
				Unlocked: unlocked,
				Total:    total,
				Message:  "Pencapaian investigator tersinkron.",
			}

			return nil
		},
	)

	return response, err
}

func (s *Server) achievementsSyncHandler(
	w http.ResponseWriter,
	r *http.Request,
) {
	if r.Method != http.MethodPost {
		respondError(
			w,
			http.StatusMethodNotAllowed,
			"Gunakan POST.",
		)
		return
	}

	uid, err := s.authenticate(r)
	if err != nil {
		respondError(
			w,
			http.StatusUnauthorized,
			"Autentikasi diperlukan.",
		)
		return
	}

	result, err := s.syncAchievements(r.Context(), uid)
	if err != nil {
		log.Printf("achievement sync failed: %v", err)

		respondError(
			w,
			http.StatusInternalServerError,
			"Gagal menyinkronkan pencapaian.",
		)
		return
	}

	jsonResponse(w, http.StatusOK, result)
}
