package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"time"
)

// 本文件负责生成设备本机 CA，以及续签用于 MITM 的叶子证书。
//
// CA 私钥由 Swift 侧保存到 Keychain，Go 侧只在需要时接收 PEM 文本，
// 不做任何持久化。

const (
	caKeyBits     = 2048
	caValidYears  = 5
	leafValidDays = 397 // 遵循 Apple 对服务器证书有效期的上限要求
)

// ensureSerialNumber 生成一个 128 位随机序列号。
func randomSerialNumber() (*big.Int, error) {
	limit := new(big.Int).Lsh(big.NewInt(1), 128)
	return rand.Int(rand.Reader, limit)
}

// generateCA 生成一套自签根证书，返回证书和私钥的 PEM 文本。
func generateCA() (certPEM []byte, keyPEM []byte, err error) {
	privateKey, err := rsa.GenerateKey(rand.Reader, caKeyBits)
	if err != nil {
		return nil, nil, fmt.Errorf("生成 CA 私钥失败: %w", err)
	}

	serial, err := randomSerialNumber()
	if err != nil {
		return nil, nil, fmt.Errorf("生成 CA 序列号失败: %w", err)
	}

	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:   caCommonName,
			Organization: []string{caOrganization},
		},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.AddDate(caValidYears, 0, 0),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            0,
		MaxPathLenZero:        true,
	}

	der, err := x509.CreateCertificate(rand.Reader, template, template, &privateKey.PublicKey, privateKey)
	if err != nil {
		return nil, nil, fmt.Errorf("签发 CA 证书失败: %w", err)
	}

	keyDER, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		return nil, nil, fmt.Errorf("编码 CA 私钥失败: %w", err)
	}

	certPEM = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM = pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})
	return certPEM, keyPEM, nil
}

// parseCA 校验并载入一套 CA 证书与私钥。
func parseCA(certPEM, keyPEM []byte) (*tls.Certificate, error) {
	if len(certPEM) == 0 || len(keyPEM) == 0 {
		return nil, errors.New("CA 证书或私钥为空")
	}

	certBlock, _ := pem.Decode(certPEM)
	if certBlock == nil {
		return nil, errors.New("CA 证书 PEM 解析失败")
	}
	leaf, err := x509.ParseCertificate(certBlock.Bytes)
	if err != nil {
		return nil, fmt.Errorf("CA 证书 X509 解析失败: %w", err)
	}
	if !leaf.IsCA {
		return nil, errors.New("提供的证书不是 CA 证书")
	}

	keyBlock, _ := pem.Decode(keyPEM)
	if keyBlock == nil {
		return nil, errors.New("CA 私钥 PEM 解析失败")
	}
	privateKey, err := parsePrivateKey(keyBlock.Bytes)
	if err != nil {
		return nil, err
	}

	// 校验证书公钥与私钥是同一对。少了这一步，A 的证书配 B 的私钥也能通过，
	// 代理启动后 MITM 握手会失败，而报错点离根因很远。
	if err := ensureKeyPairMatches(leaf.PublicKey, privateKey); err != nil {
		return nil, err
	}

	return &tls.Certificate{
		Certificate: [][]byte{certBlock.Bytes},
		PrivateKey:  privateKey,
		Leaf:        leaf,
	}, nil
}

// ensureKeyPairMatches 确认证书公钥与私钥来自同一密钥对。
//
// 当前实现只支持 RSA——CA 生成走的就是 RSA，且 CA 签发叶子证书也依赖它。
func ensureKeyPairMatches(certPublicKey, privateKey any) error {
	rsaPrivateKey, ok := privateKey.(*rsa.PrivateKey)
	if !ok {
		return errors.New("CA 私钥不是 RSA 类型")
	}
	rsaPublicKey, ok := certPublicKey.(*rsa.PublicKey)
	if !ok {
		return errors.New("CA 证书公钥不是 RSA 类型")
	}
	if !rsaPublicKey.Equal(&rsaPrivateKey.PublicKey) {
		return errors.New("CA 证书与私钥不匹配")
	}
	return nil
}

// parsePrivateKey 兼容 PKCS#8 和 PKCS#1 两种私钥编码。
func parsePrivateKey(der []byte) (any, error) {
	if key, err := x509.ParsePKCS8PrivateKey(der); err == nil {
		return key, nil
	}
	if key, err := x509.ParsePKCS1PrivateKey(der); err == nil {
		return key, nil
	}
	return nil, errors.New("无法解析 CA 私钥")
}

// validateCA 供 Swift 侧在启动前做一次快速有效性检查。
//
// 校验项全部收敛在 parseCA 里：PEM 可解析、证书确实是 CA、
// 以及私钥与证书公钥配对（配错会让 MITM 握手静默失败）。
func validateCA(certPEM, keyPEM []byte) error {
	if _, err := parseCA(certPEM, keyPEM); err != nil {
		return err
	}
	return nil
}

// buildMITMLeafTemplate 构造用于中间人的动态证书模板。
// 只有在 goproxy 内部按 SNI 动态签发时才用到。
func buildMITMLeafTemplate(host string) *x509.Certificate {
	now := time.Now()
	template := &x509.Certificate{
		Subject:   pkix.Name{CommonName: host},
		NotBefore: now.Add(-time.Hour),
		NotAfter:  now.AddDate(0, 0, leafValidDays),
		KeyUsage:  x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage: []x509.ExtKeyUsage{
			x509.ExtKeyUsageServerAuth,
		},
	}
	if ip := net.ParseIP(host); ip != nil {
		template.IPAddresses = []net.IP{ip}
	} else {
		template.DNSNames = []string{host}
	}
	return template
}
