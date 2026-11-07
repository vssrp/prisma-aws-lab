resource "random_id" "suffix" {
  byte_length = 4
}

module "app_bucket" {
  source      = "./modules/secure-s3"
  bucket_name = "sriram-lab-app-${random_id.suffix.hex}"
}

data "aws_vpc" "default" {
  default = true
}

resource "aws_security_group" "web" {
  #checkov:skip=CKV2_AWS_5:Lab SG, attached to an instance later
  name        = "lab-web"
  description = "Lab web SG, SSH from the private network only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH from internal range"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  egress {
    description = "HTTPS out"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}