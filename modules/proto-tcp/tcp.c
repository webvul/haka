#include "haka/tcp.h"

#include <stdlib.h>
#include <string.h>

#include <haka/log.h>
#include <haka/error.h>

struct tcp_pseudo_header {
	ipv4addr       src;
	ipv4addr       dst;
	uint8          reserved;
	uint8          proto;
	uint16         len;
};

struct tcp *tcp_dissect(struct ipv4 *packet)
{
	struct tcp *tcp = NULL;

	if (ipv4_get_payload_length(packet) < sizeof(struct tcp_header)) {
		error(L"TCP header length should have a minimum size of  %d", sizeof(struct tcp_header));
		return NULL;
	}

	/* Not a TCP packet */
	if (ipv4_get_proto(packet) != TCP_PROTO) {
		error(L"not a tcp packet");
		return NULL;
	}

	tcp = malloc(sizeof(struct tcp));
	if (!tcp) {
		error(L"Failed to allocate memory");
		return NULL;
	}
	tcp->packet = packet;
	tcp->header = (struct tcp_header*)(ipv4_get_payload(packet));
	tcp->modified = false;
	tcp->invalid_checksum = false;

	return tcp;
}

void tcp_forge(struct tcp *tcp)
{
	if (tcp->invalid_checksum)
		tcp_compute_checksum(tcp);
}

void tcp_release(struct tcp *tcp)
{
	free(tcp);
}


void tcp_pre_modify(struct tcp *tcp)
{
	if (!tcp->modified) {
		tcp->header = (struct tcp_header *)(packet_data_modifiable(tcp->packet->packet) + ipv4_get_hdr_len(tcp->packet));
	}
	tcp->modified = true;
	tcp->invalid_checksum = true;
}

int16 tcp_checksum(const struct tcp *tcp)
{
	struct tcp_pseudo_header tcp_pseudo_h;

	/* fill tcp pseudo header */
	tcp_pseudo_h.src = tcp->packet->header->src;
	tcp_pseudo_h.dst = tcp->packet->header->dst;
	tcp_pseudo_h.reserved = 0;
	tcp_pseudo_h.proto = tcp->packet->header->proto;
	tcp_pseudo_h.len = SWAP_TO_BE(uint16, ipv4_get_payload_length(tcp->packet));

	/* compute checksum */
	long sum;
	uint16 sum1, sum2;

	sum1 = ~inet_checksum((uint16 *)&tcp_pseudo_h, sizeof(struct tcp_pseudo_header));
	sum2 = ~inet_checksum((uint16 *)tcp->header, ipv4_get_payload_length(tcp->packet));

	sum = sum1 + sum2;

	while (sum >> 16)
		sum = (sum & 0xffff) + (sum >> 16);

	sum = ~sum;

	return sum;
}


bool tcp_verify_checksum(const struct tcp *tcp)
{
	return tcp_checksum(tcp) == 0;
}

void tcp_compute_checksum(struct tcp *tcp)
{
	tcp_pre_modify(tcp);
	tcp->header->checksum = 0;
	tcp->header->checksum = tcp_checksum(tcp);
	tcp->invalid_checksum = false;
}

const uint8 *tcp_get_payload(const struct tcp *tcp)
{
	return ((const uint8 *)tcp->header) + tcp_get_hdr_len(tcp);
}

uint8 *tcp_get_payload_modifiable(struct tcp *tcp)
{
	tcp_pre_modify(tcp);
	return (uint8 *)tcp_get_payload(tcp);
}

size_t tcp_get_payload_length(const struct tcp *tcp)
{
	return ipv4_get_payload_length(tcp->packet) - tcp_get_hdr_len(tcp);
}