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

data "aws_iam_policy_document" "assume_role_codebuild" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild_execution_role" {
  name               = "MyCodeBuildRole"
  assume_role_policy = data.aws_iam_policy_document.assume_role_codebuild.json
}

resource "aws_codebuild_project" "my_nginx" {
  name = "my_nginx"
  service_role = aws_iam_role.codebuild_execution_role.arn
  artifacts {
    type = "NO_ARTIFACTS"
  }
  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image = "aws/codebuild/amazonlinux2-x86_64-standard:2.0"
    type = "LINUX_CONTAINER"
    privileged_mode = true

    environment_variable {
      name = "AWS_ACCOUNT_ID"
      value = "181804339651"
      type = "PLAINTEXT"
    }
    environment_variable {
      name = "AWS_DEFAULT_REGION"
      value = "ap-northeast-1"
      type = "PLAINTEXT"
    }
    environment_variable {
      name = "IMAGE_REPO_NAME"
      value = "my-nginx"
      type = "PLAINTEXT"
    }
    environment_variable {
      name = "IMAGE_TAG"
      value = "latest"
      type = "PLAINTEXT"
    }
  }
  source {
    type = "GITHUB"
    location = "https://github.com/akapo001/terraform-ecr-ecs.git"
    git_clone_depth = 1
    git_submodules_config {
      fetch_submodules = true
    }
  }
  source_version = "main"
}

resource "aws_iam_role_policy_attachment" "amazon_ec2_container_registry_full_access" {
  role       = aws_iam_role.codebuild_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"
}

resource "aws_iam_role_policy_attachment" "amazon_ec2_container_registry_power_user" {
  role       = aws_iam_role.codebuild_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_iam_policy" "codebuild_base_policy" {
  name = "CodeBuildBasePolicy-my_nginx"
  policy = jsonencode({
    Version: "2012-10-17",
    Statement: [
      {
        Effect: "Allow",
        Resource: [
          "arn:aws:logs:ap-northeast-1:181804339651:log-group:/aws/codebuild/my_nginx",
          "arn:aws:logs:ap-northeast-1:181804339651:log-group:/aws/codebuild/my_nginx:*"
        ],
        Action: [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
      },
      {
        Effect: "Allow",
        Resource: [
          "arn:aws:s3:::codepipeline-ap-northeast-1-*"
        ],
        Action: [
          "s3:PutObject",
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:GetBucketAcl",
          "s3:GetBucketLocation"
        ]
      },
      {
        Effect: "Allow",
        Action: [
          "codebuild:CreateReportGroup",
          "codebuild:CreateReport",
          "codebuild:UpdateReport",
          "codebuild:BatchPutTestCases",
          "codebuild:BatchPutCodeCoverages"
        ],
        Resource: [
          "arn:aws:codebuild:ap-northeast-1:181804339651:report-group/my_nginx-*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "codebuild_policy" {
  role       = aws_iam_role.codebuild_execution_role.name

  policy_arn = aws_iam_policy.codebuild_base_policy.arn
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