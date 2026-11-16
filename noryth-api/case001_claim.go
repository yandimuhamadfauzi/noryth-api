package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// ==========================================================
// NORYTH - CASE #001 SECURE REWARD
//
// POST /api/cases/001/hint
// POST /api/cases/001/claim
//
// - Firebase Authentication
// - SQL validation on server
// - Server-tracked hint usage
// - Atomic Firestore transaction
// - XP only once
// - Level and Rank synchronization
// ==========================================================

type Case001ClaimRequest struct {
	Query string `json:"query"`
}

func (s *Server) case001HintHandler(
	w http.ResponseWriter,
	r *http.Request,
) {
	if r.Method != http.MethodPost {
		respondError(w, http.StatusMethodNotAllowed, "Gunakan POST.")
		return
	}

	uid, err := s.authenticate(r)
	if err != nil {
		respondError(w, http.StatusUnauthorized, err.Error())
		return
	}

	ref := s.db.Collection("users").
		Doc(uid).
		Collection("missionPractice").
		Doc("case_001")

	err = s.db.RunTransaction(
		r.Context(),
		func(ctx context.Context, tx *firestore.Transaction) error {
			snapshot, err := tx.Get(ref)

			if err != nil && status.Code(err) != codes.NotFound {
				return err
			}

			data := map[string]interface{}{}
			if err == nil {
				data = snapshot.Data()
			}

			// Petunjuk yang pernah digunakan selalu
			// bernilai true. Tidak boleh dikembalikan false.
			if boolValue(data["hintUsed"]) {
				return nil
			}

			return tx.Set(
				ref,
				map[string]interface{}{
					"hintUsed":  true,
					"updatedAt": firestore.ServerTimestamp,
				},
				firestore.MergeAll,
			)
		},
	)

	if err != nil {
		log.Printf("case001 hint error: %v", err)
		respondError(
			w,
			http.StatusInternalServerError,
			"Petunjuk belum dapat dicatat.",
		)
		return
	}

	jsonResponse(w, http.StatusOK, map[string]interface{}{
		"success":  true,
		"hintUsed": true,
		"message":  "Penggunaan petunjuk telah dicatat.",
	})
}

func (s *Server) case001ClaimHandler(
	w http.ResponseWriter,
	r *http.Request,
) {
	if r.Method != http.MethodPost {
		respondError(w, http.StatusMethodNotAllowed, "Gunakan POST.")
		return
	}

	uid, err := s.authenticate(r)
	if err != nil {
		respondError(w, http.StatusUnauthorized, err.Error())
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 8192)
	defer r.Body.Close()

	var request Case001ClaimRequest

	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()

	if err := decoder.Decode(&request); err != nil {
		respondError(
			w,
			http.StatusBadRequest,
			"Format request SQL tidak valid.",
		)
		return
	}

	var extra interface{}
	if err := decoder.Decode(&extra); err != io.EOF {
		respondError(
			w,
			http.StatusBadRequest,
			"Body harus berisi satu objek JSON.",
		)
		return
	}

	validation := validateCase001SQL(request.Query)

	if !validation.Valid {
		respondError(
			w,
			http.StatusUnprocessableEntity,
			"Query SQL tidak didukung validator server.",
		)
		return
	}

	if !validation.Correct {
		respondError(
			w,
			http.StatusUnprocessableEntity,
			"Jawaban SQL belum memenuhi tujuan investigasi.",
		)
		return
	}

	response, err := s.awardCase001(r.Context(), uid)

	if err != nil {
		log.Printf("case001 claim error: %v", err)
		respondError(
			w,
			http.StatusConflict,
			"Reward belum dapat diproses.",
		)
		return
	}

	jsonResponse(w, http.StatusOK, response)
}

func (s *Server) awardCase001(
	ctx context.Context,
	uid string,
) (ClaimResponse, error) {
	userRef := s.db.Collection("users").Doc(uid)

	case001Ref := userRef.
		Collection("missionPractice").
		Doc("case_001")

	case002Ref := userRef.
		Collection("missionPractice").
		Doc("case_002")

	result := ClaimResponse{}

	err := s.db.RunTransaction(
		ctx,
		func(ctx context.Context, tx *firestore.Transaction) error {
			// Semua pembacaan sebelum penulisan.
			userSnap, err := tx.Get(userRef)
			if err != nil {
				return fmt.Errorf("pengguna tidak ditemukan: %w", err)
			}

			case001Snap, err := tx.Get(case001Ref)
			if err != nil && status.Code(err) != codes.NotFound {
				return err
			}
			case001Exists := err == nil

			case002Snap, err := tx.Get(case002Ref)
			if err != nil && status.Code(err) != codes.NotFound {
				return err
			}
			case002Exists := err == nil

			userData := userSnap.Data()

			case001Data := map[string]interface{}{}
			if case001Exists {
				case001Data = case001Snap.Data()
			}

			case002Data := map[string]interface{}{}
			if case002Exists {
				case002Data = case002Snap.Data()
			}

			oldXP := intValue(userData["xp"])
			if oldXP < 0 {
				return fmt.Errorf("nilai XP tidak valid")
			}

			alreadyPaid := boolValue(case001Data["xpAwarded"])
			hintUsed := boolValue(case001Data["hintUsed"])

			reward := int64(200)
			if hintUsed {
				reward = 150
			}

			earned := int64(0)
			if !alreadyPaid {
				earned = reward
			}

			newXP := oldXP + earned
			level := calculateNorythLevel(newXP)

			// Kasus #001 dinyatakan selesai setelah
			// query diverifikasi oleh backend.
			completed := int64(1)

			if boolValue(case002Data["practiceCompleted"]) {
				completed++
			}

			oldCompleted := intValue(
				userData["completedMissions"],
			)
			if oldCompleted > completed {
				completed = oldCompleted
			}

			userUpdates := []firestore.Update{
				{Path: "level", Value: level.Level},
				{Path: "rank", Value: level.Rank},
				{Path: "completedMissions", Value: completed},
				{
					Path:  "updatedAt",
					Value: firestore.ServerTimestamp,
				},
			}

			if earned > 0 {
				userUpdates = append(
					userUpdates,
					firestore.Update{
						Path:  "xp",
						Value: firestore.Increment(earned),
					},
				)
			}

			if err := tx.Update(userRef, userUpdates); err != nil {
				return err
			}

			// Status penyelesaian dipastikan oleh server.
			progressUpdate := map[string]interface{}{
				"practiceCompleted": true,
				"updatedAt":         firestore.ServerTimestamp,
			}

			if _, exists := case001Data["completedAt"]; !exists {
				progressUpdate["completedAt"] =
					firestore.ServerTimestamp
			}

			if !alreadyPaid {
				progressUpdate["xpAwarded"] = true
				progressUpdate["xpEarned"] = reward
				progressUpdate["xpAwardedAt"] =
					firestore.ServerTimestamp
			}

			if err := tx.Set(
				case001Ref,
				progressUpdate,
				firestore.MergeAll,
			); err != nil {
				return err
			}

			result = ClaimResponse{
				Success:     true,
				AlreadyPaid: alreadyPaid,
				AwardedXp:   earned,
				TotalXp:     newXP,
			}

			if alreadyPaid {
				result.Message =
					"Reward Kasus #001 sebelumnya sudah diberikan."
			} else {
				result.Message =
					"Reward Kasus #001 berhasil diberikan."
			}

			return nil
		},
	)

	return result, err
}
