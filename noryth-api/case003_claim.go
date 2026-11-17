package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type pythonEvidence struct {
	ID        string
	Action    string
	RiskScore int
}

var pythonCase003Logs = []pythonEvidence{
	{"PY-001", "viewed", 20},
	{"PY-002", "deleted", 96},
	{"PY-003", "updated", 35},
	{"PY-004", "deleted", 91},
	{"PY-005", "deleted", 42},
	{"PY-006", "viewed", 70},
}

// Validator subset Python, bukan interpreter Python umum.
var pythonCase003Pattern = regexp.MustCompile(
	`(?s)^\s*` +
		`([A-Za-z_]\w*)\s*=\s*` +
		`\[\s*([A-Za-z_]\w*)\s+` +
		`for\s+([A-Za-z_]\w*)\s+in\s+logs\s+` +
		`if\s+([A-Za-z_]\w*)\s*` +
		`\[\s*['"]risk_score['"]\s*\]\s*` +
		`(>=|>|<=|<|==|!=)\s*(\d+)\s+and\s+` +
		`([A-Za-z_]\w*)\s*` +
		`\[\s*['"]action['"]\s*\]\s*` +
		`(==|!=)\s*['"]([A-Za-z_]+)['"]\s*` +
		`\]\s*` +
		`print\s*\(\s*([A-Za-z_]\w*)\s*\)\s*$`,
)

func validPythonCase003Answer(source string) bool {
	if len(source) == 0 || len(source) > 4000 {
		return false
	}

	match := pythonCase003Pattern.FindStringSubmatch(source)

	if match == nil {
		return false
	}

	resultVariable := match[1]
	selectedVariable := match[2]
	loopVariable := match[3]
	riskVariable := match[4]
	riskOperator := match[5]
	thresholdText := match[6]
	actionVariable := match[7]
	actionOperator := match[8]
	actionValue := match[9]
	printVariable := match[10]

	if selectedVariable != loopVariable ||
		riskVariable != loopVariable ||
		actionVariable != loopVariable ||
		printVariable != resultVariable {
		return false
	}

	threshold, err := strconv.Atoi(thresholdText)
	if err != nil {
		return false
	}

	if riskOperator != ">=" ||
		threshold != 80 ||
		actionOperator != "==" ||
		actionValue != "deleted" {
		return false
	}

	expected := map[string]bool{
		"PY-002": true,
		"PY-004": true,
	}

	found := 0

	for _, entry := range pythonCase003Logs {
		if entry.RiskScore >= threshold &&
			entry.Action == actionValue {
			if !expected[entry.ID] {
				return false
			}
			found++
		}
	}

	return found == len(expected)
}

func (s *Server) awardCase003(
	ctx context.Context,
	uid string,
) (ClaimResponse, error) {
	userRef := s.db.Collection("users").Doc(uid)

	practiceCollection := userRef.Collection(
		"missionPractice",
	)

	case001Ref := practiceCollection.Doc("case_001")
	case002Ref := practiceCollection.Doc("case_002")
	case003Ref := practiceCollection.Doc("case_003")

	missionRef := s.db.Collection("missions").Doc(
		"case_003",
	)

	result := ClaimResponse{}

	err := s.db.RunTransaction(
		ctx,
		func(ctx context.Context, tx *firestore.Transaction) error {
			// Seluruh pembacaan dilakukan sebelum penulisan.
			missionSnap, err := tx.Get(missionRef)
			if err != nil {
				return fmt.Errorf(
					"membaca misi: %w", err,
				)
			}

			userSnap, err := tx.Get(userRef)
			if err != nil {
				return fmt.Errorf(
					"membaca pengguna: %w", err,
				)
			}

			case001Snap, err := tx.Get(case001Ref)
			case001Exists := err == nil
			if err != nil && status.Code(err) != codes.NotFound {
				return fmt.Errorf(
					"membaca case_001: %w", err,
				)
			}

			case002Snap, err := tx.Get(case002Ref)
			case002Exists := err == nil
			if err != nil && status.Code(err) != codes.NotFound {
				return fmt.Errorf(
					"membaca case_002: %w", err,
				)
			}

			case003Snap, err := tx.Get(case003Ref)
			case003Exists := err == nil
			if err != nil && status.Code(err) != codes.NotFound {
				return fmt.Errorf(
					"membaca case_003: %w", err,
				)
			}

			missionData := missionSnap.Data()
			userData := userSnap.Data()

			published := boolValue(
				missionData["isPublished"],
			)
			playable := boolValue(
				missionData["isPlayable"],
			)
			missionStatus := strings.ToLower(
				strings.TrimSpace(
					stringValue(missionData["status"]),
				),
			)

			if !published ||
				!playable ||
				missionStatus != "active" {
				return errors.New(
					"case_003 belum aktif",
				)
			}

			reward := intValue(
				missionData["xpReward"],
			)

			if reward <= 0 || reward > 1000 {
				return errors.New(
					"xpReward case_003 tidak valid",
				)
			}

			oldXP := intValue(userData["xp"])
			if oldXP < 0 {
				return errors.New(
					"XP pengguna tidak valid",
				)
			}

			case001Data := map[string]interface{}{}
			case002Data := map[string]interface{}{}
			case003Data := map[string]interface{}{}

			if case001Exists {
				case001Data = case001Snap.Data()
			}

			if case002Exists {
				case002Data = case002Snap.Data()
			}

			if case003Exists {
				case003Data = case003Snap.Data()
			}

			alreadyPaid := boolValue(
				case003Data["xpAwarded"],
			)

			awardedXP := int64(0)

			if !alreadyPaid {
				awardedXP = reward
			}

			newXP := oldXP + awardedXP
			levelProgress := calculateNorythLevel(newXP)

			completedMissions := int64(1)

			if boolValue(
				case001Data["practiceCompleted"],
			) {
				completedMissions++
			}

			if boolValue(
				case002Data["practiceCompleted"],
			) {
				completedMissions++
			}

			oldCompleted := intValue(
				userData["completedMissions"],
			)

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
						Path: "xp",
						Value: firestore.Increment(
							awardedXP,
						),
					},
				)
			}

			if err := tx.Update(
				userRef,
				userUpdates,
			); err != nil {
				return fmt.Errorf(
					"memperbarui profil: %w", err,
				)
			}

			attempts := intValue(
				case003Data["attempts"],
			)
			if attempts < 1 {
				attempts = 1
			}

			progressData := map[string]interface{}{
				"attempts":          attempts,
				"practiceCompleted": true,
				"xpAwarded":         true,
			}

			if !alreadyPaid {
				progressData["xpEarned"] = reward
				progressData["xpAwardedAt"] =
					firestore.ServerTimestamp
			}

			if _, exists := case003Data["completedAt"]; !exists {
				progressData["completedAt"] =
					firestore.ServerTimestamp
			}

			if err := tx.Set(
				case003Ref,
				progressData,
				firestore.MergeAll,
			); err != nil {
				return fmt.Errorf(
					"menyimpan progres: %w", err,
				)
			}

			message := "Reward sudah pernah diberikan."

			if !alreadyPaid {
				message = "Kasus #003 berhasil diselesaikan."
			}

			result = ClaimResponse{
				Success:     true,
				AlreadyPaid: alreadyPaid,
				AwardedXp:   awardedXP,
				TotalXp:     newXP,
				Message:     message,
			}

			return nil
		},
	)

	return result, err
}

func (s *Server) case003ClaimHandler(
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

	if !validPythonCase003Answer(request.Code) {
		respondError(
			w,
			http.StatusUnprocessableEntity,
			"Jawaban Python belum sesuai.",
		)
		return
	}

	response, err := s.awardCase003(
		r.Context(),
		uid,
	)

	if err != nil {
		log.Printf(
			"case_003 claim failed: %v",
			err,
		)

		respondError(
			w,
			http.StatusConflict,
			"Reward Kasus #003 belum dapat diproses.",
		)
		return
	}

	jsonResponse(
		w,
		http.StatusOK,
		response,
	)
}
