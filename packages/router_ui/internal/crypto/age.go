package crypto

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"io"
	"math/big"
	"os"

	"filippo.io/age"
)

type AgeEncryptor struct {
	identity age.Identity
}

// NewAgeEncryptor creates a new age encryptor with a key from the given path
func NewAgeEncryptor(keyPath string) (*AgeEncryptor, error) {
	keyData, err := os.ReadFile(keyPath)
	if err != nil {
		// If key doesn't exist, generate a new one
		if os.IsNotExist(err) {
			identity, err := age.GenerateX25519Identity()
			if err != nil {
				return nil, fmt.Errorf("failed to generate identity: %w", err)
			}
			
			// Save the private key
			if err := os.WriteFile(keyPath, []byte(identity.String()), 0600); err != nil {
				return nil, fmt.Errorf("failed to save identity: %w", err)
			}
			
			return &AgeEncryptor{identity: identity}, nil
		}
		return nil, fmt.Errorf("failed to read key: %w", err)
	}

	identity, err := age.ParseX25519Identity(string(keyData))
	if err != nil {
		return nil, fmt.Errorf("failed to parse identity: %w", err)
	}

	return &AgeEncryptor{identity: identity}, nil
}

// Encrypt encrypts data using age
func (e *AgeEncryptor) Encrypt(plaintext []byte) (string, error) {
	// Get the recipient from the identity
	// In age v1, X25519Identity implements both Identity and Recipient
	recipient := e.identity.(age.Recipient)

	var buf bytes.Buffer
	w, err := age.Encrypt(&buf, recipient)
	if err != nil {
		return "", fmt.Errorf("failed to create encryptor: %w", err)
	}

	if _, err := w.Write(plaintext); err != nil {
		return "", fmt.Errorf("failed to write encrypted data: %w", err)
	}

	if err := w.Close(); err != nil {
		return "", fmt.Errorf("failed to close encryptor: %w", err)
	}

	return base64.StdEncoding.EncodeToString(buf.Bytes()), nil
}

// Decrypt decrypts data using age
func (e *AgeEncryptor) Decrypt(ciphertext string) ([]byte, error) {
	data, err := base64.StdEncoding.DecodeString(ciphertext)
	if err != nil {
		return nil, fmt.Errorf("failed to decode base64: %w", err)
	}

	r, err := age.Decrypt(bytes.NewReader(data), e.identity)
	if err != nil {
		return nil, fmt.Errorf("failed to create decryptor: %w", err)
	}

	plaintext, err := io.ReadAll(r)
	if err != nil {
		return nil, fmt.Errorf("failed to read decrypted data: %w", err)
	}

	return plaintext, nil
}

// GeneratePassword generates a random password
func GeneratePassword(length int) (string, error) {
	const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*"
	b := make([]byte, length)
	for i := range b {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(charset))))
		if err != nil {
			return "", err
		}
		b[i] = charset[n.Int64()]
	}
	return string(b), nil
}