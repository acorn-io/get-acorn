FROM nginx
COPY ./default.conf /etc/nginx/conf.d/default.conf
COPY ./get.sh /usr/share/nginx/html/index.txt
