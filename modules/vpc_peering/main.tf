data "aws_region" "accepter" {
  provider = aws.accepter
}

resource "aws_vpc_peering_connection" "this" {
  provider = aws.requester

  vpc_id      = var.requester_vpc_id
  peer_vpc_id = var.accepter_vpc_id
  peer_region = data.aws_region.accepter.name
  auto_accept = false

  tags = {
    Name = var.name
  }
}

resource "aws_vpc_peering_connection_accepter" "this" {
  provider = aws.accepter

  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
  auto_accept               = true

  tags = {
    Name = var.name
  }
}

# DNS options are relative to the VPC that owns each block. The requester
# option controls resolving requester hostnames from the accepter; the accepter
# option controls resolving accepter hostnames from the requester.
resource "aws_vpc_peering_connection_options" "requester" {
  provider = aws.requester

  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id

  requester {
    allow_remote_vpc_dns_resolution = var.requester_dns_resolution_enabled
  }
}

# Allow the requester (near/client) VPC to resolve the accepter (far/database)
# VPC's public DB endpoint to its private IP. The response direction is already
# routed by the reciprocal peering routes.
resource "aws_vpc_peering_connection_options" "accepter" {
  provider = aws.accepter

  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id

  accepter {
    allow_remote_vpc_dns_resolution = var.accepter_dns_resolution_enabled
  }
}

# count (not for_each): the route table IDs are only known after apply, but
# how many there are is known at plan time.
resource "aws_route" "requester_to_accepter" {
  provider = aws.requester
  count    = length(var.requester_route_table_ids)

  route_table_id            = var.requester_route_table_ids[count.index]
  destination_cidr_block    = var.accepter_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id

  depends_on = [aws_vpc_peering_connection_accepter.this]
}

resource "aws_route" "accepter_to_requester" {
  provider = aws.accepter
  count    = length(var.accepter_route_table_ids)

  route_table_id            = var.accepter_route_table_ids[count.index]
  destination_cidr_block    = var.requester_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id

  depends_on = [aws_vpc_peering_connection_accepter.this]
}
