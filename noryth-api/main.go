
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

// ==========================================================
// NORYTH API
// Kasus #002 - Jejak Digital yang Hilang
//
// - Firebase ID Token verification
// - Server-side answer validation
// - Firestore transaction
// - One-time XP reward
// ==========================================================

type Server struct {
	authClient *auth.Client
	db         *firestore.Client
	origins    map[string]bool
}

type ClaimRequest struct {
	Code string `json:"code"`
}

type ClaimResponse struct {
	Success      bool   `json:"success"`
	AlreadyPaid  bool   `json:"alreadyPaid"`
	AwardedXp    int64  `json:"awardedXp"`
	TotalXp      int64  `json:"totalXp"`
	Message      string `json:"message"`
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
	_ = json.NewEncoder(w).Encode(payload)
}

func respondError(
	w http.ResponseWriter,
	statusCode int,
	message string,
) {
	jsonResponse(
		w,
		statusCode,
		APIError{Error: message},
	)
}

// ==========================================================
// VALIDASI KODE JAVASCRIPT
//
// Ini evaluator subset, bukan runtime JavaScript penuh.
// Server tidak melakukan eval() atau menjalankan kode
// yang dikirim pemain.
//
// Bentuk yang diterima:
//
// const hasil = logs.filter(log =>
//   log.riskScore >= 80 &&
//   log.action === "deleted"
// );
//
// console.log(hasil);
//
// Perbedaan spasi, baris dan nama variabel diterima.
// ==========================================================

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
			if char == '(' {
				depth++
			}

			if char == ')' {
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

func compareInt(left int, operator string, right int) bool {
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

func compareString(left, operator, right string) bool {
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

	// Hanya dua kondisi AND yang didukung.
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

			numberText := strings.ReplaceAll(found[2], "_", "")
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

// ==========================================================
// FIRESTORE VALUE HELPERS
// ==========================================================

func intValue(value interface{}) int64 {
	switch v := value.(type) {
	case int64:
		return v
	case int:
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

// ==========================================================
// AUTHENTICATION
// ==========================================================

func (s *Server) authenticate(
	r *http.Request,
) (string, error) {
	header := r.Header.Get("Authorization")

	if !strings.HasPrefix(header, "Bearer ") {
		return "", errors.New("token login tidak tersedia")
	}

	idToken := strings.TrimSpace(
		strings.TrimPrefix(header, "Bearer "),
	)

	if idToken == "" {
		return "", errors.New("token kosong")
	}

	token, err := s.authClient.VerifyIDToken(
		r.Context(),
		idToken,
	)

	if err != nil {
		return "", errors.New("token tidak valid")
	}

	return token.UID, nil
}

// ==========================================================
// CLAIM XP - FIRESTORE TRANSACTION
// ==========================================================

func (s *Server) awardCase002(
	ctx context.Context,
	uid string,
) (ClaimResponse, error) {
	userRef := s.db.Collection("users").Doc(uid)

	progressRef := userRef.
		Collection("missionPractice").
		Doc("case_002")

	missionRef := s.db.
		Collection("missions").
		Doc("case_002")

	response := ClaimResponse{}

	err := s.db.RunTransaction(
		ctx,
		func(ctx context.Context, tx *firestore.Transaction) error {

			// Semua read sebelum write.
			missionSnap, err := tx.Get(missionRef)
			if err != nil {
				return fmt.Errorf("misi tidak dapat dibaca: %w", err)
			}

			userSnap, err := tx.Get(userRef)
			if err != nil {
				return fmt.Errorf("pengguna tidak ditemukan: %w", err)
			}

			progressSnap, err := tx.Get(progressRef)

			progressExists := err == nil

			if err != nil &&
				status.Code(err) != codes.NotFound {
				return fmt.Errorf("gagal membaca progres: %w", err)
			}

			missionData := missionSnap.Data()
			userData := userSnap.Data()

			if !boolValue(missionData["isPublished"]) ||
				strings.ToLower(
					strings.TrimSpace(
						stringValue(missionData["status"]),
					),
				) != "active" {
				return errors.New("kasus belum aktif")
			}

			reward := intValue(missionData["xpReward"])

			if reward <= 0 || reward > 1000 {
				return errors.New("reward XP tidak valid")
			}

			oldXP := intValue(userData["xp"])

			var progressData map[string]interface{}

			if progressExists {
				progressData = progressSnap.Data()
			} else {
				progressData = map[string]interface{}{}
			}

			// Idempotensi: hadiah yang sudah diberikan
			// tidak akan diberikan ulang.
			if boolValue(progressData["xpAwarded"]) {
				response = ClaimResponse{
					Success:     true,
					AlreadyPaid: true,
					AwardedXp:   0,
					TotalXp:     oldXP,
					Message:     "Hadiah sudah pernah diberikan.",
				}
				return nil
			}

			// Integrasi dengan progres lama:
			// practiceCompleted mungkin sudah true,
			// tetapi xpAwarded masih false.
			// Kode tetap harus diverifikasi server
			// sebelum fungsi ini dipanggil.

			newXP := oldXP + reward

			// Pertahankan attempts lama.
			attempts := intValue(progressData["attempts"])
			if attempts < 1 {
				attempts = 1
			}

			update := map[string]interface{}{
				"attempts":         attempts,
				"practiceCompleted": true,
				"xpAwarded":         true,
				"xpEarned":          reward,
				"xpAwardedAt":       firestore.ServerTimestamp,
			}

			// Jangan timpa waktu selesai sebelumnya.
			if _, exists := progressData["completedAt"]; !exists {
				update["completedAt"] = firestore.ServerTimestamp
			}

			if err := tx.Update(
				userRef,
				[]firestore.Update{
					{
						Path:  "xp",
						Value: firestore.Increment(reward),
					},
					{
						Path:  "updatedAt",
						Value: firestore.ServerTimestamp,
					},
				},
			); err != nil {
				return err
			}

			if err := tx.Set(
				progressRef,
				update,
				firestore.MergeAll,
			); err != nil {
				return err
			}

			response = ClaimResponse{
				Success:     true,
				AlreadyPaid: false,
				AwardedXp:   reward,
				TotalXp:     newXP,
				Message:     "Hadiah XP berhasil diberikan.",
			}

			return nil
		},
	)

	return response, err
}

// ==========================================================
// HTTP HANDLERS
// ==========================================================

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

	r.Body = http.MaxBytesReader(w, r.Body, 8192)
	defer r.Body.Close()

	var request ClaimRequest

	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()

	if err := decoder.Decode(&request); err != nil {
		respondError(
			w,
			http.StatusBadRequest,
			"Format data tidak valid.",
		)
		return
	}

	// Tidak boleh ada JSON tambahan.
	var extra interface{}
	if err := decoder.Decode(&extra); err != io.EOF {
		respondError(
			w,
			http.StatusBadRequest,
			"Body harus berisi satu objek JSON.",
		)
		return
	}

	// Validasi dilakukan DI SERVER.
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
		log.Printf("claim failed: %v", err)

		respondError(
			w,
			http.StatusConflict,
			"Reward belum dapat diproses.",
		)
		return
	}

	jsonResponse(w, http.StatusOK, response)
}

func (s *Server) withCORS(
	next http.Handler,
) http.Handler {
	return http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			origin := r.Header.Get("Origin")

			if origin != "" && s.origins[origin] {
				w.Header().Set(
					"Access-Control-Allow-Origin",
					origin,
				)
				w.Header().Set(
					"Vary",
					"Origin",
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
				if origin != "" && !s.origins[origin] {
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

// ==========================================================
// MAIN
// ==========================================================

func main() {
	ctx := context.Background()

	projectID := os.Getenv("FIREBASE_PROJECT_ID")
	serviceAccount := os.Getenv("FIREBASE_SERVICE_ACCOUNT_JSON")

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
		"/api/cases/002/claim",
		server.claimHandler,
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

	log.Printf("Noryth API berjalan di port %s", port)

	log.Fatal(httpServer.ListenAndServe())
}
