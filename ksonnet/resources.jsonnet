
//
// Definition for VPN resources on Kubernetes.
//

// Import KSonnet library.
local k = import "ksonnet.beta.2/k.libsonnet";

// Short-cuts to various objects in the KSonnet library.
local depl = k.extensions.v1beta1.deployment;
local container = depl.mixin.spec.template.spec.containersType;
local containerPort = container.portsType;
local mount = container.volumeMountsType;
local volume = depl.mixin.spec.template.spec.volumesType;
local resources = container.resourcesType;
local env = container.envType;
local gceDisk = volume.mixin.gcePersistentDisk;
local svc = k.core.v1.service;
local svcPort = svc.mixin.spec.portsType;
local sessionAffinity = svc.mixin.spec.sessionAffinity;
local svcLabels = svc.mixin.metadata.labels;
local externalIp = svc.mixin.spec.loadBalancerIp;
local svcType = svc.mixin.spec.type;
local secretDisk = volume.mixin.secret;

// VPN service.  Provides a strongswan VPN.
local vpnSvc(config) = {

    // ipsec-svc service plus cyberprobe.  There's nothing to trigger the
    // cyberprobe to do something useful, as there's no cyberprobe-sync.
    
    name: "ipsec-svc",
    // FIXME: This seems ugly.
    cyberprobeVersion:: import "../ksonnet/cyberprobe-version.jsonnet",
    ipsecAddrSyncVersion:: import "ipsec-addr-sync-version.jsonnet",
    vpnServiceVersion:: import "version.jsonnet",
    images: [
    	config.containerBase + "/ipsec-svc:" + self.vpnServiceVersion,
    	config.containerBase + "/ipsec-addr-sync:" + self.ipsecAddrSyncVersion,
	"cybermaggedon/cyberprobe:" + self.cyberprobeVersion
    ],

    // Environment variables
    local envs = [
      // FQDN of VPN
      env.new("FQDN", config.ipsecService.fqdn)
    ],
            
    // Ports for VPN, has DHCP client
    local vpnPorts = [
        containerPort.newNamed("ike", 500),     // IKE
        containerPort.newNamed("esp", 4500)     // ESP
    ],

    local cyberprobeCmd = "cyberprobe /config/cyberprobe.cfg",

    // Init containers
    local initContainers = [

	// InitContainer which configures the iptables for masquerading
	container.new("init-masq", self.images[0]) +
            container.command(["sh", "-c",
			       "iptables -t nat -A POSTROUTING -s 10.8.0.0/16 -o eth0 -m policy --dir out --pol ipsec -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.8.0.0/16 -o eth0 -j MASQUERADE"]) +
            container.mixin.securityContext.capabilities.add("NET_ADMIN"),
    ],
    // Containers
    local containers = [
	
	// NET_ADMIN allows VPN service to create and use the /dev/tun*
	// devices.
        // IPsec VPN
        container.new(self.name, self.images[0]) +
            container.env(envs) +
            container.ports(vpnPorts) +
	    container.volumeMounts([
                mount.new("vpn-svc-creds", "/key") + mount.readOnly(true),
                mount.new("shared-config", "/config")
	    ]) +
            container.mixin.resources.limits({
                memory: "512M", cpu: "1.5"
            }) +
            container.mixin.resources.requests({
                memory: "512M", cpu: "0.5"
            }) +
            container.mixin.securityContext.capabilities.add("NET_ADMIN"),

        // DHCP server
        container.new("dhcp", self.images[0]) +
	    container.volumeMounts([
                mount.new("vpn-svc-creds", "/key")
	    ]) +
            container.mixin.resources.limits({
                memory: "64M", cpu: "0.25"
            }) +
            container.mixin.resources.requests({
                memory: "64M", cpu: "0.05"
            }) +
            container.command(["/usr/local/bin/dhcp-server"]),

        // ipsec-addr-sync
        container.new("sync", self.images[1]) +
	    container.volumeMounts([
		mount.new("shared-config", "/config")
	    ]) +
            container.mixin.resources.limits({
                memory: "64M", cpu: "0.1"
            }) +
            container.mixin.resources.requests({
                memory: "64M", cpu: "0.1"
            }),

        // cyberprobe
        container.new("cyberprobe", self.images[2]) +
	    container.volumeMounts([
                mount.new("vpn-probe-creds", "/probe-creds"),
		mount.new("shared-config", "/config")
	    ]) +
            container.mixin.resources.limits({
                memory: "128M", cpu: "0.1"
            }) +
            container.mixin.resources.requests({
                memory: "128M", cpu: "0.1"
            }) +
            container.command(["sh", "-c", cyberprobeCmd]) +
            container.mixin.securityContext.capabilities.add("NET_ADMIN")

    ],
    // Volumes - this invokes a secret containing the cert/key
    local volumes = [

        // vpn-svc-creds secret
        volume.name("vpn-svc-creds") +
            secretDisk.secretName("vpn-svc-creds"),

        // vpn-probe-creds secret
        volume.name("vpn-probe-creds") +
            secretDisk.secretName("vpn-probe-creds"),

        // shared config
        volume.fromEmptyDir("shared-config")

    ],
    // Deployments
    deployments:: [
        depl.new("ipsec-vpn", config.ipsecService.replicas,
		 containers,
                 {app: "ipsec-vpn", component: "access"}) +
            depl.mixin.spec.template.spec.volumes(volumes) +
            depl.mixin.metadata.namespace(config.namespace) +
	    depl.mixin.spec.template.spec.initContainers(initContainers)
    ],
    // Ports used by the service.
    local servicePorts = [
        svcPort.newNamed("ike", 500, 500) + svcPort.protocol("UDP"),
        svcPort.newNamed("esp", 4500, 4500) + svcPort.protocol("UDP")
    ],

    // Service
    services:: [
        svc.new("ipsec-vpn", {app: "ipsec-vpn"}, servicePorts) +

           // Load-balancer and external IP address
           externalIp(config.addresses.ipsecService) + svcType("LoadBalancer") +

           // This traffic policy ensures observed IP addresses are the external
           // ones
           svc.mixin.spec.externalTrafficPolicy("Local") +

           // Label
           svcLabels({app: "ipsec-vpn", component: "access"}) +

           svc.mixin.metadata.namespace(config.namespace) +

           sessionAffinity("ClientIP")
    ],

    resources:
        if config.options.includeIpsec then
            self.deployments + self.services
        else []

};

[vpnSvc]

