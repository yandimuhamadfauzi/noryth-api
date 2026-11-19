package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"cloud.google.com/go/firestore"
	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/auth"
	"google.golang.org/api/option"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type Server struct {
	authClient *auth.Client
	db         *firestore.Client
	origins    map[string]bool
}

type ClaimRequest struct {
	Code string `json:"code"`
}

type ClaimResponse struct {
	Success     bool   `json:"success"`
	AlreadyPaid bool   `json:"alreadyPaid"`
	AwardedXp   int64  `json:"awardedXp"`
	TotalXp     int64  `json:"totalXp"`
	Message     string `json:"message"`
}

type APIError struct {
	Error string `json:"error"`
}

func jsonResponse(
	w http.ResponseWriter,
	statusCode int,
	payload interface{},
) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(statusCode)

	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Printf("JSON response error: %v", err)
	}
}

func respondError(
	w http.ResponseWriter,
	statusCode int,
	message string,
) {
	jsonResponse(w, statusCode, APIError{
		Error: message,
	})
}

// JavaScript Case #002

var filterPattern = regexp.MustCompile(
	`(?s)^\s*` +
		`(?:(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*)?` +
		`logs\s*\.\s*filter\s*\(\s*` +
		`([A-Za-z_$][A-Za-z0-9_$]*)\s*=>\s*` +
		`(.*?)\s*\)\s*;?\s*` +
		`(?:console\s*\.\s*log\s*\(\s*` +
		`([A-Za-z_$][A-Za-z0-9_$]*)\s*\)\s*;?\s*)?$`,
)

type DigitalLog struct {
	ID        string
	RiskScore int
	Action    string
}

var evidence = []DigitalLog{
	{"LOG-001", 15, "viewed"},
	{"LOG-002", 95, "deleted"},
	{"LOG-003", 35, "edited"},
	{"LOG-004", 88, "deleted"},
	{"LOG-005", 20, "deleted"},
	{"LOG-006", 97, "downloaded"},
	{"LOG-007", 80, "viewed"},
}

func unwrapParentheses(value string) string {
	value = strings.TrimSpace(value)

	for strings.HasPrefix(value, "(") &&
		strings.HasSuffix(value, ")") {

		depth := 0
		wrapped := true

		for index, char := range value {
			switch char {
			case '(':
				depth++
			case ')':
				depth--
			}

			if depth == 0 && index < len(value)-1 {
				wrapped = false
				break
			}
		}

		if !wrapped || depth != 0 {
			break
		}

		value = strings.TrimSpace(
			value[1 : len(value)-1],
		)
	}

	return value
}

func compareInt(
	left int,
	operator string,
	right int,
) bool {
	switch operator {
	case "==", "===":
		return left == right
	case "!=", "!==":
		return left != right
	case ">=":
		return left >= right
	case "<=":
		return left <= right
	case ">":
		return left > right
	case "<":
		return left < right
	}

	return false
}

func compareString(
	left string,
	operator string,
	right string,
) bool {
	switch operator {
	case "==", "===":
		return left == right
	case "!=", "!==":
		return left != right
	}

	return false
}

func validJavaScriptAnswer(source string) bool {
	if len(source) == 0 || len(source) > 4000 {
		return false
	}

	match := filterPattern.FindStringSubmatch(source)

	if match == nil {
		return false
	}

	resultName := match[1]
	itemName := match[2]
	expression := unwrapParentheses(match[3])
	loggedName := match[4]

	if loggedName != "" &&
		(resultName == "" || loggedName != resultName) {
		return false
	}

	parts := strings.Split(expression, "&&")

	if len(parts) != 2 {
		return false
	}

	riskPattern := regexp.MustCompile(
		`^` + regexp.QuoteMeta(itemName) +
			`\s*\.\s*riskScore\s*` +
			`(===|!==|==|!=|>=|<=|>|<)\s*` +
			`(\d[\d_]*)$`,
	)

	actionPattern := regexp.MustCompile(
		`^` + regexp.QuoteMeta(itemName) +
			`\s*\.\s*action\s*` +
			`(===|!==|==|!=)\s*` +
			`(?:"([^"]*)"|'([^']*)')$`,
	)

	var riskCondition func(DigitalLog) bool
	var actionCondition func(DigitalLog) bool

	for _, raw := range parts {
		part := unwrapParentheses(raw)

		if found := riskPattern.FindStringSubmatch(part); found != nil {
			if riskCondition != nil {
				return false
			}

			numberText := strings.ReplaceAll(
				found[2], "_", "",
			)

			number, err := strconv.Atoi(numberText)

			if err != nil {
				return false
			}

			operator := found[1]

			riskCondition = func(entry DigitalLog) bool {
				return compareInt(
					entry.RiskScore,
					operator,
					number,
				)
			}

			continue
		}

		if found := actionPattern.FindStringSubmatch(part); found != nil {
			if actionCondition != nil {
				return false
			}

			value := found[2]

			if found[3] != "" {
				value = found[3]
			}

			operator := found[1]

			actionCondition = func(entry DigitalLog) bool {
				return compareString(
					entry.Action,
					operator,
					value,
				)
			}

			continue
		}

		return false
	}

	if riskCondition == nil || actionCondition == nil {
		return false
	}

	expected := map[string]bool{
		"LOG-002": true,
		"LOG-004": true,
	}

	foundCount := 0

	for _, entry := range evidence {
		if riskCondition(entry) && actionCondition(entry) {
			if !expected[entry.ID] {
				return false
			}

			foundCount++
		}
	}

	return foundCount == len(expected)
}

// Firestore helpers

func intValue(value interface{}) int64 {
	switch v := value.(type) {
	case int64:
		return v
	case int:
		return int64(v)
	case int32:
		return int64(v)
	case float64:
		return int64(v)
	default:
		return 0
	}
}

func boolValue(value interface{}) bool {
	v, ok := value.(bool)
	return ok && v
}

func stringValue(value interface{}) string {
	v, ok := value.(string)

	if !ok {
		return ""
	}

	return v
}

// Authentication

func (s *Server) authenticate(
	r *http.Request,
) (string, error) {
	header := r.Header.Get("Authorization")

	if !strings.HasPrefix(header, "Bearer ") {
		return "", errors.New(
			"token login tidak tersedia",
		)
	}

	idToken := strings.TrimSpace(
		strings.TrimPrefix(header, "Bearer "),
	)

	if idToken == "" {
		return "", errors.New("token login kosong")
	}

	token, err := s.authClient.VerifyIDToken(
		r.Context(),
		idToken,
	)

	if err != nil {
		return "", errors.New(
			"token login tidak valid",
		)
	}

	return token.UID, nil
}

// Level and Rank

type NorythLevelProgress struct {
	Level int64
	Rank  string
}

func calculateNorythLevel(xp int64) NorythLevelProgress {
	if xp < 0 {
		xp = 0
	}

	level := int64(1)
	nextLevelAt := int64(200)

	for xp >= nextLevelAt {
		level++

		requiredForNext :=
			int64(200) + (level-1)*100

		nextLevelAt += requiredForNext
	}

	rank := "Rekrut"

	switch {
	case level >= 11:
		rank = "Master Detective"
	case level >= 8:
		rank = "Senior Investigator"
	case level >= 5:
		rank = "Investigator"
	case level >= 3:
		rank = "Analis Digital"
	}

	return NorythLevelProgress{
		Level: level,
		Rank:  rank,
	}
}

// Case #002 reward

func (s *Server) awardCase002(
	ctx context.Context,
	uid string,
) (ClaimResponse, error) {
	userRef := s.db.Collection("users").Doc(uid)

	practiceCollection := userRef.Collection(
		"missionPractice",
	)

	case001Ref := practiceCollection.Doc("case_001")
	case002Ref := practiceCollection.Doc("case_002")

	missionRef := s.db.Collection("missions").Doc(
		"case_002",
	)

	result := ClaimResponse{}

	err := s.db.RunTransaction(
		ctx,
		func(
			ctx context.Context,
			tx *firestore.Transaction,
		) error {
			missionSnap, err := tx.Get(missionRef)

			if err != nil {
				return fmt.Errorf(
					"gagal membaca katalog case_002: %w",
					err,
				)
			}

			userSnap, err := tx.Get(userRef)

			if err != nil {
				return fmt.Errorf(
					"gagal membaca pengguna: %w",
					err,
				)
			}

			case001Snap, err := tx.Get(case001Ref)
			case001Exists := err == nil

			if err != nil &&
				status.Code(err) != codes.NotFound {
				return fmt.Errorf(
					"gagal membaca case_001: %w",
					err,
				)
			}

			case002Snap, err := tx.Get(case002Ref)
			case002Exists := err == nil

			if err != nil &&
				status.Code(err) != codes.NotFound {
				return fmt.Errorf(
					"gagal membaca case_002: %w",
					err,
				)
			}

			missionData := missionSnap.Data()
			userData := userSnap.Data()

			published := boolValue(
				missionData["isPublished"],
			)

			missionStatus := strings.ToLower(
				strings.TrimSpace(
					stringValue(missionData["status"]),
				),
			)

			if !published || missionStatus != "active" {
				return errors.New(
					"kasus #002 belum aktif",
				)
			}

			reward := intValue(
				missionData["xpReward"],
			)

			if reward <= 0 || reward > 1000 {
				return errors.New(
					"xpReward case_002 tidak valid",
				)
			}

			oldXP := intValue(userData["xp"])

			if oldXP < 0 {
				return errors.New(
					"nilai XP pengguna tidak valid",
				)
			}

			case001Data := map[string]interface{}{}
			case002Data := map[string]interface{}{}

			if case001Exists {
				case001Data = case001Snap.Data()
			}

			if case002Exists {
				case002Data = case002Snap.Data()
			}

			alreadyPaid := boolValue(
				case002Data["xpAwarded"],
			)

			awardedXP := int64(0)

			if !alreadyPaid {
				awardedXP = reward
			}

			newTotalXP := oldXP + awardedXP

			levelProgress := calculateNorythLevel(
				newTotalXP,
			)

			completedMissions := int64(1)

			if boolValue(
				case001Data["practiceCompleted"],
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
					"gagal menyimpan statistik: %w",
					err,
				)
			}

			progressUpdate := map[string]interface{}{
				"practiceCompleted": true,
				"updatedAt":         firestore.ServerTimestamp,
			}

			if _, exists := case002Data["attempts"]; !exists {
				progressUpdate["attempts"] = int64(1)
			}

			if _, exists := case002Data["completedAt"]; !exists {
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
				case002Ref,
				progressUpdate,
				firestore.MergeAll,
			); err != nil {
				return fmt.Errorf(
					"gagal menyimpan progres case_002: %w",
					err,
				)
			}

			result = ClaimResponse{
				Success:     true,
				AlreadyPaid: alreadyPaid,
				AwardedXp:   awardedXP,
				TotalXp:     newTotalXP,
			}

			if alreadyPaid {
				result.Message =
					"Hadiah sebelumnya sudah diberikan. " +
						"Status penyelesaian, Level, dan " +
						"Rank telah disinkronkan."
			} else {
				result.Message =
					"Kasus #002 berhasil diselesaikan. " +
						"Reward, Level, dan Rank " +
						"telah disimpan."
			}

			return nil
		},
	)

	return result, err
}

// Case #002 handler

func (s *Server) claimHandler(
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
			"Format request tidak valid.",
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

	if !validJavaScriptAnswer(request.Code) {
		respondError(
			w,
			http.StatusUnprocessableEntity,
			"Jawaban JavaScript belum benar.",
		)
		return
	}

	response, err := s.awardCase002(
		r.Context(),
		uid,
	)

	if err != nil {
		log.Printf(
			"case002 claim failed: %v",
			err,
		)

		respondError(
			w,
			http.StatusConflict,
			"Progres atau reward belum dapat diproses.",
		)
		return
	}

	jsonResponse(
		w,
		http.StatusOK,
		response,
	)
}

// CORS

func (s *Server) withCORS(
	next http.Handler,
) http.Handler {
	return http.HandlerFunc(
		func(
			w http.ResponseWriter,
			r *http.Request,
		) {
			origin := r.Header.Get("Origin")

			if origin != "" {
				w.Header().Add("Vary", "Origin")
			}

			if origin != "" && s.origins[origin] {
				w.Header().Set(
					"Access-Control-Allow-Origin",
					origin,
				)

				w.Header().Set(
					"Access-Control-Allow-Headers",
					"Authorization, Content-Type",
				)

				w.Header().Set(
					"Access-Control-Allow-Methods",
					"POST, OPTIONS",
				)
			}

			if r.Method == http.MethodOptions {
				if origin != "" &&
					!s.origins[origin] {
					w.WriteHeader(http.StatusForbidden)
					return
				}

				w.WriteHeader(http.StatusNoContent)
				return
			}

			next.ServeHTTP(w, r)
		},
	)
}

// Main server

func main() {
	ctx := context.Background()

	projectID := strings.TrimSpace(
		os.Getenv("FIREBASE_PROJECT_ID"),
	)

	serviceAccount := os.Getenv(
		"FIREBASE_SERVICE_ACCOUNT_JSON",
	)

	if projectID == "" || serviceAccount == "" {
		log.Fatal(
			"FIREBASE_PROJECT_ID dan " +
				"FIREBASE_SERVICE_ACCOUNT_JSON wajib diisi",
		)
	}

	credential := option.WithCredentialsJSON(
		[]byte(serviceAccount),
	)

	app, err := firebase.NewApp(
		ctx,
		&firebase.Config{
			ProjectID: projectID,
		},
		credential,
	)

	if err != nil {
		log.Fatal(err)
	}

	authClient, err := app.Auth(ctx)

	if err != nil {
		log.Fatal(err)
	}

	db, err := app.Firestore(ctx)

	if err != nil {
		log.Fatal(err)
	}

	defer db.Close()

	origins := map[string]bool{}

	for _, origin := range strings.Split(
		os.Getenv("ALLOWED_ORIGINS"),
		",",
	) {
		origin = strings.TrimSpace(origin)

		if origin != "" {
			origins[origin] = true
		}
	}

	server := &Server{
		authClient: authClient,
		db:         db,
		origins:    origins,
	}

	mux := http.NewServeMux()

	mux.HandleFunc(
		"/health",
		func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodGet {
				respondError(
					w,
					http.StatusMethodNotAllowed,
					"Gunakan GET.",
				)
				return
			}

			jsonResponse(
				w,
				http.StatusOK,
				map[string]string{
					"status": "ok",
				},
			)
		},
	)

	mux.HandleFunc(
		"/api/cases/001/hint",
		server.case001HintHandler,
	)

	mux.HandleFunc(
		"/api/cases/001/claim",
		server.case001ClaimHandler,
	)

	mux.HandleFunc(
		"/api/cases/002/claim",
		server.claimHandler,
	)

	mux.HandleFunc(
		"/api/cases/003/claim",
		server.case003ClaimHandler,
	)

	mux.HandleFunc(
		"/api/cases/003/attempt",
		server.case003AttemptHandler,
	)

	mux.HandleFunc(
		"/api/cases/003/submit",
		server.case003SubmitHandler,
	)

	mux.HandleFunc(
		"/api/achievements/sync",
		server.achievementsSyncHandler,
	)

	port := os.Getenv("PORT")

	if port == "" {
		port = "8080"
	}

	httpServer := &http.Server{
		Addr:              ":" + port,
		Handler:           server.withCORS(mux),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
	}

	log.Printf(
		"Noryth API berjalan di port %s",
		port,
	)

	log.Fatal(
		httpServer.ListenAndServe(),
	)
}
