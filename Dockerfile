FROM centos:centos7

RUN yum install -y httpd

EXPOSE 80

CMD ["/usr/sbin/httpd", "-D", "FOREGROUND"]