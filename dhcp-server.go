// Example of minimal DHCP server:
package main

import (
	dhcp "github.com/krolaw/dhcp4"
	"log"
	"crypto/x509"
	"io/ioutil"
	"net"
	"time"
	"fmt"
	"net/http"
	"crypto/tls"
	"strings"
)

// Example using DHCP with a single network interface device
func main() {

	serverIP := net.IP{0, 0, 0, 0}
	routerIP := net.IP{10, 8, 0, 1}
	dnsIP := net.IP{8, 8, 8, 8}

	caCert, err := ioutil.ReadFile("/key/cert.ca")
	if err != nil {
		log.Fatal(err)
	}
	
	caCertPool := x509.NewCertPool()
	caCertPool.AppendCertsFromPEM(caCert)

	cert, err := tls.LoadX509KeyPair("/key/cert.allocator",
		"/key/key.allocator")
	if err != nil {
		log.Fatal(err)
	}

        client := &http.Client{
                Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				RootCAs:      caCertPool,
				Certificates: []tls.Certificate{cert},
			},
		},
	}

	handler := &DHCPHandler{
		ip:            serverIP,
		// 2 week lease.
		leaseDuration: 24 * 14 * time.Hour,
		options: dhcp.Options{
			dhcp.OptionSubnetMask:       []byte{255, 255, 0, 0},
			dhcp.OptionRouter:           []byte(routerIP),
			dhcp.OptionDomainNameServer: []byte(dnsIP),
		},
		client: client,
	}

	log.Fatal(dhcp.ListenAndServe(handler))

}

type DHCPHandler struct {
	ip            net.IP        // Server IP to use
	options       dhcp.Options  // Options to send to DHCP Clients
	leaseDuration time.Duration // Lease period
	client        *http.Client
}

func (h *DHCPHandler) AddrForHost(host []byte) (net.IP, error) {

	fmt.Println("  Host", string(host))

	hoststr := string(host)

	// Discard everything after '.', if present.
	parts := strings.SplitN(hoststr, ".", 2)
	if len(parts) > 0 {
		hoststr = parts[0]
	}
	
	fmt.Println("  Device is", hoststr)

	url := "https://addresses.ops.trustnetworks.com/get/" + hoststr
	resp, err := h.client.Get(url)
	if err != nil {
		return nil, err
	}
	
	address, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	resp.Body.Close()

	ip := net.ParseIP(string(address))

	fmt.Println("  Allocated", ip)

	return ip, nil

}

func (h *DHCPHandler) ServeDHCP(p dhcp.Packet, msgType dhcp.MessageType, options dhcp.Options) (d dhcp.Packet) {

	switch msgType {

	case dhcp.Discover:
		fmt.Println("Discover")
		hostname, ok := options[dhcp.OptionHostName]
		if !ok {
			// No hostname, ignore.
			return
		}
		offerIP, err := h.AddrForHost(hostname)
		if err != nil {
			fmt.Println(err)
			return
		}
		fmt.Println("  Replying with", offerIP)
		return dhcp.ReplyPacket(p, dhcp.Offer, h.ip, offerIP,
			h.leaseDuration,
			h.options.SelectOrderOrAll(options[dhcp.OptionParameterRequestList]))

	case dhcp.Request:
		fmt.Println("Request")
		if server, ok := options[dhcp.OptionServerIdentifier]; ok && !net.IP(server).Equal(h.ip) {
			fmt.Println("  Not for me")
			// Message not for this dhcp server
			return nil
		}

		reqIP := net.IP(options[dhcp.OptionRequestedIPAddress])
		var err error

		if reqIP == nil {
			hostname, ok := options[dhcp.OptionHostName]
			if !ok {
				// No hostname, ignore.
				return
			}
			reqIP, err = h.AddrForHost(hostname)
			if err != nil {
				fmt.Println(err)
			}
		}

		if len(reqIP) == 4 && !reqIP.Equal(net.IPv4zero) {
					fmt.Println("  Reply: ", reqIP)
			return dhcp.ReplyPacket(p, dhcp.ACK,
				h.ip, reqIP, h.leaseDuration,
				h.options.SelectOrderOrAll(options[dhcp.OptionParameterRequestList]))
		}

		fmt.Println("  NAK")
		return dhcp.ReplyPacket(p, dhcp.NAK, h.ip, nil, 0, nil)

	case dhcp.Release, dhcp.Decline:
		// Do nothing.
	}
	return nil
}
