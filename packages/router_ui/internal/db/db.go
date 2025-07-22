package db

import (
	"encoding/json"
	"fmt"

	badger "github.com/dgraph-io/badger/v4"
)

type DB struct {
	db *badger.DB
}

func New(path string) (*DB, error) {
	opts := badger.DefaultOptions(path)
	opts.Logger = nil // Disable badger logs for now
	
	db, err := badger.Open(opts)
	if err != nil {
		return nil, fmt.Errorf("failed to open badger: %w", err)
	}

	return &DB{db: db}, nil
}

func (d *DB) Close() error {
	return d.db.Close()
}

func (d *DB) Get(key string) ([]byte, error) {
	var value []byte
	err := d.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get([]byte(key))
		if err != nil {
			return err
		}
		return item.Value(func(val []byte) error {
			value = append([]byte{}, val...)
			return nil
		})
	})
	return value, err
}

func (d *DB) Set(key string, value []byte) error {
	return d.db.Update(func(txn *badger.Txn) error {
		return txn.Set([]byte(key), value)
	})
}

func (d *DB) Delete(key string) error {
	return d.db.Update(func(txn *badger.Txn) error {
		return txn.Delete([]byte(key))
	})
}

func (d *DB) GetJSON(key string, v interface{}) error {
	data, err := d.Get(key)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, v)
}

func (d *DB) SetJSON(key string, v interface{}) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return d.Set(key, data)
}

func (d *DB) List(prefix string) ([]string, error) {
	var keys []string
	err := d.db.View(func(txn *badger.Txn) error {
		opts := badger.DefaultIteratorOptions
		opts.PrefetchValues = false
		it := txn.NewIterator(opts)
		defer it.Close()

		prefixBytes := []byte(prefix)
		for it.Seek(prefixBytes); it.ValidForPrefix(prefixBytes); it.Next() {
			item := it.Item()
			keys = append(keys, string(item.Key()))
		}
		return nil
	})
	return keys, err
}