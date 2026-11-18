package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type Case003SubmitResponse struct {
	Success     bool   `json:"success"`
	Correct     bool   `json:"correct"`
	Attempts    int64  `json:"attempts"`
	Completed   bool   `json:"completed"`
	AlreadyPaid bool   `json:"alreadyPaid"`
	AwardedXp   int64  `json:"awardedXp"`
	TotalXp     int64  `json:"totalXp"`
	Message     string `json:"message"`
}

func (s *Server) submitCase003(
	ctx context.Context,
	uid string,
	correct bool,
) (Case003SubmitResponse, error) {
	userRef := s.db.Collection("users").Doc(uid)
	practice := userRef.Collection("missionPractice")

	case001Ref := practice.Doc("case_001")
	case002Ref := practice.Doc("case_002")
	case003Ref := practice.Doc("case_003")

	missionRef := s.db.Collection("missions").Doc("case_003")
	historyRef := case003Ref.Collection("attemptHistory").NewDoc()

	var response Case003SubmitResponse

	err := s.db.RunTransaction(
		ctx,
		func(ctx context.Context, tx *firestore.Transaction) error {
			userSnap, err := tx.Get(userRef)
			if err != nil {
				return fmt.Errorf("gagal membaca pengguna: %w", err)
			}

			progressSnap, err := tx.Get(case003Ref)
			if err != nil && status.Code(err) != codes.NotFound {
				return fmt.Errorf("gagal membaca progres Python: %w", err)
			}

			userData := userSnap.Data()
			progressData := map[string]interface{}{}

			if err == nil {
				progressData = progressSnap.Data()
			}

			attempts := intValue(progressData["attempts"])
			if attempts < 0 || attempts >= 1000000000 {
				return errors.New("jumlah percobaan tidak valid")
			}
			attempts++

			oldXP := intValue(userData["xp"])
			if oldXP < 0 {
				return errors.New("XP pengguna tidak valid")
			}

			alreadyPaid := boolValue(progressData["xpAwarded"])
			completed := boolValue(progressData["practiceCompleted"])

			awardedXP := int64(0)
			newXP := oldXP

			progressUpdate := map[string]interface{}{
				"attempts":        attempts,
				"lastCodeCorrect": correct,
				"lastAttemptAt":   firestore.ServerTimestamp,
				"updatedAt":       firestore.ServerTimestamp,
			}

			if correct {
				missionSnap, err := tx.Get(missionRef)
				if err != nil {
					return fmt.Errorf(
						"gagal membaca katalog case_003: %w",
						err,
					)
				}

				missionData := missionSnap.Data()

				published := boolValue(missionData["isPublished"])
				playable := boolValue(missionData["isPlayable"])
				missionStatus := strings.ToLower(
					strings.TrimSpace(stringValue(missionData["status"])),
				)

				if !published || !playable || missionStatus != "active" {
					return errors.New("case_003 belum aktif")
				}

				reward := intValue(missionData["xpReward"])
				if reward <= 0 || reward > 1000 {
					return errors.New("xpReward case_003 tidak valid")
				}

				case001Snap, err := tx.Get(case001Ref)
				if err != nil && status.Code(err) != codes.NotFound {
					return fmt.Errorf("gagal membaca case_001: %w", err)
				}

				case001Data := map[string]interface{}{}
				if err == nil {
					case001Data = case001Snap.Data()
				}

				case002Snap, err := tx.Get(case002Ref)
				if err != nil && status.Code(err) != codes.NotFound {
					return fmt.Errorf("gagal membaca case_002: %w", err)
				}

				case002Data := map[string]interface{}{}
				if err == nil {
					case002Data = case002Snap.Data()
				}

				if !alreadyPaid {
					awardedXP = reward
				}

				newXP = oldXP + awardedXP
				levelProgress := calculateNorythLevel(newXP)

				completedMissions := int64(1)

				if boolValue(case001Data["practiceCompleted"]) {
					completedMissions++
				}

				if boolValue(case002Data["practiceCompleted"]) {
					completedMissions++
				}

				oldCompleted := intValue(userData["completedMissions"])
				if oldCompleted > completedMissions {
					completedMissions = oldCompleted
				}

				userUpdates := []firestore.Update{
					{
						Path:  "level",
						Value: levelProgress.Level,
					},
					{
						Path:  "rank",
						Value: levelProgress.Rank,
					},
					{
						Path:  "completedMissions",
						Value: completedMissions,
					},
					{
						Path:  "updatedAt",
						Value: firestore.ServerTimestamp,
					},
				}

				if awardedXP > 0 {
					userUpdates = append(
						userUpdates,
						firestore.Update{
							Path:  "xp",
							Value: firestore.Increment(awardedXP),
						},
					)
				}

				progressUpdate["practiceCompleted"] = true

				if !completed {
					if _, exists := progressData["completedAt"]; !exists {
						progressUpdate["completedAt"] =
							firestore.ServerTimestamp
					}
				}

				if !alreadyPaid {
					progressUpdate["xpAwarded"] = true
					progressUpdate["xpEarned"] = reward
					progressUpdate["xpAwardedAt"] =
						firestore.ServerTimestamp
				}

				if err := tx.Update(userRef, userUpdates); err != nil {
					return fmt.Errorf(
						"gagal memperbarui profil: %w",
						err,
					)
				}

				completed = true
			}

			if err := tx.Set(
				case003Ref,
				progressUpdate,
				firestore.MergeAll,
			); err != nil {
				return fmt.Errorf("gagal menyimpan progres: %w", err)
			}

			historyData := map[string]interface{}{
				"attemptNumber": attempts,
				"correct":       correct,
				"rewardGranted": awardedXP > 0,
				"awardedXp":     awardedXP,
				"createdAt":     firestore.ServerTimestamp,
			}

			if err := tx.Set(historyRef, historyData); err != nil {
				return fmt.Errorf(
					"gagal menyimpan riwayat case_003: %w",
					err,
				)
			}

			message := "Percobaan tersimpan. Jawaban belum sesuai."

			if correct {
				if alreadyPaid {
					message = "Kasus sudah selesai. XP tidak diberikan ulang."
				} else {
					message = "Kasus #003 berhasil diselesaikan."
				}
			}

			response = Case003SubmitResponse{
				Success:     true,
				Correct:     correct,
				Attempts:    attempts,
				Completed:   completed,
				AlreadyPaid: alreadyPaid,
				AwardedXp:   awardedXP,
				TotalXp:     newXP,
				Message:     message,
			}

			return nil
		},
	)

	return response, err
}

func (s *Server) case003SubmitHandler(
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
			err.Error(),
		)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 8192)
	defer r.Body.Close()

	var request ClaimRequest

	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()

	if err := decoder.Decode(&request); err != nil {
		respondError(
			w,
			http.StatusBadRequest,
			"Format JSON tidak valid.",
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

	code := strings.TrimSpace(request.Code)

	if len(code) == 0 || len(code) > 4000 {
		respondError(
			w,
			http.StatusBadRequest,
			"Kode wajib diisi, maksimal 4000 byte.",
		)
		return
	}

	correct := validPythonCase003Answer(code)

	result, err := s.submitCase003(
		r.Context(),
		uid,
		correct,
	)

	if err != nil {
		log.Printf("case003 submit failed: %v", err)

		respondError(
			w,
			http.StatusConflict,
			"Percobaan Kasus #003 belum dapat diproses.",
		)
		return
	}

	jsonResponse(w, http.StatusOK, result)
}
