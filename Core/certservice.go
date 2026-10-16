package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"net/http"
	"sync"
	"time"
)

// 证书服务提供两个本地端点：
//
//	GET http://127.0.0.1:<随机端口>/ca.cer   —— 下载根证书，供 Safari 安装描述文件
//	GET https://127.0.0.1:<随机端口>/health  —— 用系统信任链校验叶子证书
//
// 第二个端点很关键：它由根证书签出的 127.0.0.1 叶子证书提供服务，如果 iOS
// 已经完整信任该根证书，那么客户端用默认参数即可握手成功；因此「请求 /health
// 是否成功」就是「CA 是否已安装并信任」的可验证判据，无需读取系统信任设置。
type certificateService struct {
	httpServer  *http.Server
	httpsServer *http.Server
	httpListener  net.Listener
	httpsListener net.Listener
	leafHash    string
	closeOnce   sync.Once
	closeErr    error
}

// startCertificateService 启动证书服务，监听端口由系统随机分配。
func startCertificateService(caCertPEM, caKeyPEM []byte) (*certificateService, error) {
	ca, err := parseCA(caCertPEM, caKeyPEM)
	if err != nil {
		return nil, err
	}
	if !ca.Leaf.IsCA {
		return nil, errors.New("证书服务需要 CA 证书")
	}

	leaf, leafDER, err := issueLoopbackLeaf(ca)
	if err != nil {
		return nil, err
	}

	httpListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	httpsListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		_ = httpListener.Close()
		return nil, err
	}

	rootDER := ca.Leaf.Raw

	downloadMux := http.NewServeMux()
	downloadMux.HandleFunc("/ca.cer", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/x-x509-ca-cert")
		w.Header().Set("Content-Disposition", `attachment; filename="Newloc-CA.cer"`)
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write(rootDER)
	})
	// 方便用户在浏览器里直接访问根路径时被引导到证书下载。
	downloadMux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(`<!DOCTYPE html><html><head><meta charset="utf-8">` +
			`<title>CA Certificate</title></head><body>` +
			`<p><a href="/ca.cer">下载 CA 证书</a></p></body></html>`))
	})

	probeMux := http.NewServeMux()
	probeMux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write([]byte("ok\n"))
	})

	service := &certificateService{
		httpServer:    &http.Server{Handler: downloadMux},
		httpsServer:   &http.Server{Handler: probeMux},
		httpListener:  httpListener,
		httpsListener: httpsListener,
		leafHash:      sha256Base64(leafDER),
	}

	go func() {
		if err := service.httpServer.Serve(httpListener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logEvent("证书下载服务异常: " + err.Error())
		}
	}()
	go func() {
		tlsListener := tls.NewListener(httpsListener, &tls.Config{
			Certificates: []tls.Certificate{leaf},
			MinVersion:   tls.VersionTLS12,
		})
		if err := service.httpsServer.Serve(tlsListener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logEvent("证书探测服务异常: " + err.Error())
		}
	}()

	return service, nil
}

// issueLoopbackLeaf 由 CA 签出一张仅用于 127.0.0.1 的服务器证书。
func issueLoopbackLeaf(ca *tls.Certificate) (tls.Certificate, []byte, error) {
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return tls.Certificate{}, nil, err
	}

	serial, err := randomSerialNumber()
	if err != nil {
		return tls.Certificate{}, nil, err
	}

	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:   leafCommonName,
			Organization: []string{caOrganization},
		},
		NotBefore:   now.Add(-time.Hour),
		NotAfter:    now.AddDate(0, 0, leafValidDays),
		KeyUsage:    x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:    []string{"localhost"},
		IPAddresses: []net.IP{net.ParseIP("127.0.0.1")},
	}

	der, err := x509.CreateCertificate(rand.Reader, template, ca.Leaf, &privateKey.PublicKey, ca.PrivateKey)
	if err != nil {
		return tls.Certificate{}, nil, err
	}

	keyDER, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		return tls.Certificate{}, nil, err
	}

	leaf, err := tls.X509KeyPair(
		pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}),
	)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	leaf.Leaf, err = x509.ParseCertificate(der)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	return leaf, der, nil
}

func sha256Base64(data []byte) string {
	sum := sha256.Sum256(data)
	return base64.StdEncoding.EncodeToString(sum[:])
}

// randomHex32 生成 32 位十六进制随机串，用作代理连通性验证 token。
// 16 字节经十六进制编码正好得到 32 个字符；调用方（randomUUID、验证 token）
// 都按「32 个十六进制字符」来使用，因此这里必须是 hex 而不是 base64。
func randomHex32() string {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		// 随机源不可用时退化为时间戳，仍然足以区分单次会话的验证请求。
		return big.NewInt(time.Now().UnixNano()).Text(16)
	}
	return hex.EncodeToString(buf)
}

func (s *certificateService) DownloadURL() string {
	return "http://" + s.httpListener.Addr().String() + "/ca.cer"
}

func (s *certificateService) ProbeURL() string {
	return "https://" + s.httpsListener.Addr().String() + "/health"
}

func (s *certificateService) HTTPPort() int {
	if addr, ok := s.httpListener.Addr().(*net.TCPAddr); ok {
		return addr.Port
	}
	return 0
}

func (s *certificateService) HTTPSPort() int {
	if addr, ok := s.httpsListener.Addr().(*net.TCPAddr); ok {
		return addr.Port
	}
	return 0
}

func (s *certificateService) LeafSHA256() string { return s.leafHash }

func (s *certificateService) Close() error {
	s.closeOnce.Do(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		if err := s.httpServer.Shutdown(ctx); err != nil && !errors.Is(err, http.ErrServerClosed) {
			s.closeErr = err
		}
		if err := s.httpsServer.Shutdown(ctx); err != nil && !errors.Is(err, http.ErrServerClosed) && s.closeErr == nil {
			s.closeErr = err
		}
	})
	return s.closeErr
}
