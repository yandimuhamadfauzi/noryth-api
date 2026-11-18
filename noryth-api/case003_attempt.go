package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type Case003AttemptResponse struct {
	Success  bool   `json:"success"`
	Correct  bool   `json:"correct"`
	Attempts int64  `json:"attempts"`
	Message  string `json:"message"`
}

func (s *Server) saveCase003Attempt(
	ctx context.Context,
	uid string,
	correct bool,
) (Case003AttemptResponse, error) {

	userRef := s.db.Collection("users").Doc(uid)

	progressRef := userRef.
		Collection("missionPractice").
		Doc("case_003")

	result := Case003AttemptResponse{}

	err := s.db.RunTransaction(
		ctx,
		func(
			ctx context.Context,
			tx *firestore.Transaction,
		) error {

			// Pastikan akun pemain benar-benar ada.
			_, err := tx.Get(userRef)

			if err != nil {
				return fmt.Errorf(
					"akun pemain tidak ditemukan: %w",
					err,
				)
			}

			snapshot, err := tx.Get(progressRef)

			exists := err == nil

			if err != nil &&
				status.Code(err) != codes.NotFound {
				return fmt.Errorf(
					"gagal membaca progres: %w",
					err,
				)
			}

			attempts := int64(0)

			if exists {
				attempts = intValue(
					snapshot.Data()["attempts"],
				)
			}

			if attempts < 0 {
				return fmt.Errorf(
					"jumlah percobaan tidak valid",
				)
			}

			attempts++

			update := map[string]interface{}{
				"attempts":        attempts,
				"lastCodeCorrect": correct,
				"lastAttemptAt":   firestore.ServerTimestamp,
				"updatedAt":       firestore.ServerTimestamp,
			}

			// Merge menjaga xpAwarded,
			// xpEarned, completedAt, dan field
			// penyelesaian resmi tetap utuh.
			if err := tx.Set(
				progressRef,
				update,
				firestore.MergeAll,
			); err != nil {
				return fmt.Errorf(
					"gagal menyimpan percobaan: %w",
					err,
				)
			}

			message := "Percobaan tersimpan."

			if correct {
				message =
					"Jawaban benar. Siap diverifikasi untuk reward."
			}

			result = Case003AttemptResponse{
				Success:  true,
				Correct:  correct,
				Attempts: attempts,
				Message:  message,
			}

			return nil
		},
	)

	return result, err
}

func (s *Server) case003AttemptHandler(
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

	r.Body = http.MaxBytesReader(
		w,
		r.Body,
		8192,
	)
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
			"Body harus satu objek JSON.",
		)
		return
	}

	source := strings.TrimSpace(request.Code)

	if len(source) == 0 || len(source) > 4000 {
		respondError(
			w,
			http.StatusBadRequest,
			"Kode wajib diisi dan maksimal 4000 byte.",
		)
		return
	}

	correct := validPythonCase003Answer(source)

	result, err := s.saveCase003Attempt(
		r.Context(),
		uid,
		correct,
	)

	if err != nil {
		log.Printf(
			"case003 attempt failed: %v",
			err,
		)

		respondError(
			w,
			http.StatusInternalServerError,
			"Gagal menyimpan percobaan Python.",
		)
		return
	}

	jsonResponse(
		w,
		http.StatusOK,
		result,
	)
}
