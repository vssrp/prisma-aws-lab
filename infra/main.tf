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
  name   = "lab-web"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}