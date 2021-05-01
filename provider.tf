# AWS基本設定
provider "aws" {
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
  region     = "ap-northeast-1"
}

resource "aws_ecr_repository" "nginx" {
  name                 = "my-nginx"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
}

output "ecr_url" {
  value = aws_ecr_repository.nginx.repository_url
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "MyEcsTaskRole"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachment" "amazon_ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "cloud_watch_agent_server_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_ecs_task_definition" "task" {
  cpu    = "256"
  memory = "512"

  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      logConfiguration : {
        logDriver : "awslogs",
        options : {
          awslogs-group : "/ecs/my-nginx",
          awslogs-region : "ap-northeast-1",
          awslogs-stream-prefix : "ecs"
        }
      },
      portMappings : [
        {
          hostPort : 80,
          protocol : "tcp",
          containerPort : 80
        }
      ],
      cpu : 256,
      memoryReservation : 512,
      essential : true,
      name : "my-nginx",
      image : "${aws_ecr_repository.nginx.repository_url}:latest"
    }
  ])
  family = "my-nginx"
}

resource "aws_ecs_cluster" "nginx" {
  name = "nginx"
}

resource "aws_vpc" "nginx" {
  cidr_block = "10.0.0.0/16"

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "nginx"
  }
}

resource "aws_internet_gateway" "nginx" {
  vpc_id = aws_vpc.nginx.id

  tags = {
    Name = "nginx"
  }
}

resource "aws_default_route_table" "public" {
  tags = {
    Name = "public-rt"
  }
  default_route_table_id = aws_vpc.nginx.default_route_table_id
}

resource "aws_route" "public" {
  route_table_id         = aws_default_route_table.public.id
  gateway_id             = aws_internet_gateway.nginx.id
  destination_cidr_block = "0.0.0.0/0"
}

resource "aws_subnet" "public-subnet" {
  cidr_block              = "10.0.10.0/24"
  availability_zone       = "ap-northeast-1a"
  vpc_id                  = aws_vpc.nginx.id
  map_public_ip_on_launch = true
  tags = {
    Name = "nginx-public"
  }
}

resource "aws_security_group" "nginx-sg" {
  vpc_id = aws_vpc.nginx.id
  name   = "nginx-sg"
  ingress {
    from_port   = 80
    protocol    = "TCP"
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_service" "nginx" {
  name            = "nginx-ecs"
  cluster         = aws_ecs_cluster.nginx.arn
  task_definition = "my-nginx:8"
  desired_count   = 1

  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  network_configuration {
    subnets = [
      aws_subnet.public-subnet.id
    ]

    security_groups = [
      aws_security_group.nginx-sg.id
    ]

    assign_public_ip = true
  }

}