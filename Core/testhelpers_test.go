package main

import (
	"bytes"
	"compress/gzip"
	"testing"
)

// gzipBytes 是测试辅助函数，把数据压缩成 gzip。
func gzipBytes(t *testing.T, data []byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	writer := gzip.NewWriter(&buf)
	if _, err := writer.Write(data); err != nil {
		t.Fatalf("gzip 写入失败: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("gzip 关闭失败: %v", err)
	}
	return buf.Bytes()
}
