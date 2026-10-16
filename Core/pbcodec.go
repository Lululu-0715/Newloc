package main

import (
	"errors"
	"fmt"
)

// 本文件实现一个最小可用的 Protocol Buffers 线格式编解码器。
//
// 之所以不引入 protobuf 运行时，是因为 WLOC 响应体没有公开发布的 .proto
// 定义，我们只能按字段号直接操作原始字节。手写解析器可以做到「未知字段原样
// 保留」，这是改写 Apple 二进制响应的前提——任何字段顺序或编码上的偏差都会
// 导致系统侧解析失败。

// protobuf wire type 常量。
const (
	wireVarint      = 0
	wireFixed64     = 1
	wireLengthDelim = 2
	wireFixed32     = 5
)

// pbField 表示解析后的单个字段。raw 保留原始字节（含 tag 和长度前缀），
// 用于在不需要修改时原样回写，避免重新编码引入差异。
type pbField struct {
	number   int
	wireType int
	value    []byte // 仅载荷部分：varint 字节、长度分隔段内容等
	raw      []byte // 完整原始字节：tag + 载荷
}

// readVarint 读取一个 base-128 varint，返回值和消耗的字节数。
func readVarint(data []byte) (uint64, int, error) {
	var value uint64
	for i := 0; i < len(data); i++ {
		if i >= 10 {
			return 0, 0, errors.New("varint 长度超过 10 字节")
		}
		b := data[i]
		value |= uint64(b&0x7f) << (7 * uint(i))
		if b&0x80 == 0 {
			return value, i + 1, nil
		}
	}
	return 0, 0, errors.New("varint 被截断")
}

// appendVarint 把 value 按 base-128 编码追加到 dst 并返回。
func appendVarint(dst []byte, value uint64) []byte {
	for value >= 0x80 {
		dst = append(dst, byte(value)|0x80)
		value >>= 7
	}
	return append(dst, byte(value))
}

// appendTag 追加一个字段头：field_number << 3 | wire_type。
func appendTag(dst []byte, number, wireType int) []byte {
	return appendVarint(dst, uint64(number)<<3|uint64(wireType))
}

// appendLengthDelimited 追加一个长度分隔字段。
func appendLengthDelimited(dst []byte, number int, payload []byte) []byte {
	dst = appendTag(dst, number, wireLengthDelim)
	dst = appendVarint(dst, uint64(len(payload)))
	return append(dst, payload...)
}

// appendVarintField 追加一个 varint 字段。
func appendVarintField(dst []byte, number int, value uint64) []byte {
	dst = appendTag(dst, number, wireVarint)
	return appendVarint(dst, value)
}

// decodeFields 把一段 protobuf 载荷解析成字段列表。遇到非法结构直接报错，
// 调用方应当据此放弃改写并让原始流量通过。
func decodeFields(data []byte) ([]pbField, error) {
	fields := make([]pbField, 0, 8)
	cursor := 0
	for cursor < len(data) {
		fieldStart := cursor

		tag, tagLen, err := readVarint(data[cursor:])
		if err != nil {
			return nil, err
		}
		cursor += tagLen

		number := int(tag >> 3)
		wireType := int(tag & 7)
		if number == 0 {
			return nil, errors.New("protobuf 字段号为 0")
		}

		var payload []byte
		switch wireType {
		case wireVarint:
			_, n, err := readVarint(data[cursor:])
			if err != nil {
				return nil, err
			}
			payload = clone(data[cursor : cursor+n])
			cursor += n

		case wireFixed64:
			if cursor+8 > len(data) {
				return nil, errors.New("fixed64 被截断")
			}
			payload = clone(data[cursor : cursor+8])
			cursor += 8

		case wireLengthDelim:
			length, n, err := readVarint(data[cursor:])
			if err != nil {
				return nil, err
			}
			cursor += n
			if length > uint64(len(data)-cursor) {
				return nil, errors.New("长度分隔段被截断")
			}
			payload = clone(data[cursor : cursor+int(length)])
			cursor += int(length)

		case wireFixed32:
			if cursor+4 > len(data) {
				return nil, errors.New("fixed32 被截断")
			}
			payload = clone(data[cursor : cursor+4])
			cursor += 4

		default:
			return nil, fmt.Errorf("不支持的 wire type %d", wireType)
		}

		fields = append(fields, pbField{
			number:   number,
			wireType: wireType,
			value:    payload,
			raw:      clone(data[fieldStart:cursor]),
		})
	}
	return fields, nil
}

// hasVarintField 判断字段列表中是否存在指定字段号的 varint 字段。
func hasVarintField(fields []pbField, number int) bool {
	for _, f := range fields {
		if f.number == number && f.wireType == wireVarint {
			return true
		}
	}
	return false
}

func clone(b []byte) []byte {
	return append([]byte(nil), b...)
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}
