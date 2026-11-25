{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    nmap
    nikto
    whatweb
    burpsuite
    search-vulns
    metasploit
    libpcap
    tcpdump
    ptcpdump
    dhcpdump
    shuffledns
    massdns
    masscan
    jsubfinder
    amass
    dnsrecon
    dnsenum
    fierce
    udns
    alterx
    dnsvalidator
    kdigger
    whois
    rdap
    dnstracer
    dig
    host
  ];
}
