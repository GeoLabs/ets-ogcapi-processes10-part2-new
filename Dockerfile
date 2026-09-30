#
# Prior to use this Dockerfile, please use the following commands:
#
# mkdir CITE
# cd CITE
# Options (choose only one and run the command below the option description):
#
# 1) Using the latest available teamengine release
# curl -L -o 5.5.2.zip https://github.com/opengeospatial/teamengine/archive/refs/tags/5.5.2.zip
# unzip 5.5.2.zip
# mv teamengine-5.5.2 src
#
# 2) Optionally you can rely on the latest teamengine (not working during our tests on 20230524)
# git clone https://github.com/opengeospatial/teamengine src
#
# git clone https://github.com/opengeospatial/ets-common.git src1
# cd src1
# git clone https://github.com/opengeospatial/ets-ogcapi-processes10part2.git
# cd ..
#

#
# Go inside the CITE directory
#
# Build with the following command:
#
# docker build . -f src1/ets-ogcapi-processes10part2/Dockerfile -t teamengine/ogcapi-processes10part2:latest
#
# Run using the following command:
#
# docker run -d --name cite-teamengine -p 8080:8080 teamengine/ogcapi-processes10part2:latest
#
# Log using the following command:
#
# docker logs -f cite-teamengine
#
# Stop using the following command:
#
# docker stop cite-teamengine
#
# Remove using the following command:
#
# docker rm cite-teamengine
#

#
# Build stage 1: teamengine itself. Its own pom.xml hard-pins
# <source>/<target> 1.8, and its maven-site-plugin:3.6 execution relies on
# reflection (Guice/pegdown/asciidoctor) that JDK 9+'s module system blocks
# - so it needs a JDK 8 toolchain, not the JDK 17 one below.
#
FROM maven:3.8.3-jdk-8-slim AS build-teamengine
COPY src /home/app/src
COPY patches /home/app/patches
# bullseye is EOL: deb.debian.org 404s, and its security suite isn't
# mirrored on archive.debian.org at all, so it's just dropped.
RUN sed -i 's|deb.debian.org|archive.debian.org|g; /security/d' /etc/apt/sources.list && \
    apt-get update && \
    apt-get install -y git patch && \
    cd /home/app/src && \
    git init -q && \
    git -c user.email=build@local -c user.name=build add -A && \
    git -c user.email=build@local -c user.name=build commit -q -m "snapshot" && \
    cd /home/app && \
    patch -p1 -d /home/app/src < /home/app/patches/teamengine-web-remove-virtualwebapploader.patch && \
    mvn -f /home/app/src/pom.xml clean install > log 2>&1 || (tail -300 log && exit 1)

#
# Build stage 2: ets-ogcapi-processes10-part2. Its parent pom (ets-common)
# requires JDK 17, and it depends on teamengine-spi as a Maven artifact, so
# stage 1's local repository (where that artifact was installed) is copied
# in before building - jars built with a 1.8 target load fine under 17.
#
FROM maven:3.9.9-eclipse-temurin-17-focal AS build
ARG BUILD_DEPS=" \
    git \
"
COPY --from=build-teamengine /root/.m2 /root/.m2
COPY src1 /home/app/src1
COPY jaxb-fetch-pom.xml /home/app/jaxb-fetch-pom.xml
RUN apt-get update && \
    apt-get install -y $BUILD_DEPS && \
    mvn -f /home/app/src1/ets-ogcapi-processes10-part2/pom.xml spring-javaformat:apply && \
    mvn -f /home/app/src1/ets-ogcapi-processes10-part2/pom.xml clean install && \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false $BUILD_DEPS && \
    rm -rf /var/lib/apt/lists/*
# JAXB (javax.xml.bind) was removed from the JDK in Java 11+; teamengine's
# TestSuiteController servlet still does Class.forName("javax.xml.bind...")
# at startup, so running it under this stage's JRE 17 needs the jars back
# on Tomcat's classpath. jaxb-runtime's own dependency closure is resolved
# here (rather than pinning each transitive jar by hand) and copied onto
# Tomcat's shared lib/ below.
RUN mkdir -p /home/app/jaxb-libs && \
    mvn -f /home/app/jaxb-fetch-pom.xml dependency:copy-dependencies \
        -DoutputDirectory=/home/app/jaxb-libs -DincludeScope=runtime

#
# Create the container to be run based on tomcat
#
# tomcat:10.x bundles the jakarta.servlet API (Jakarta EE 9+); teamengine-web
# (built above, shared with the main ets-ogcapi-processes10 image) still
# implements javax.servlet.Filter, so its filters ClassCastException at
# deploy time under Tomcat 10+. ets-ogcapi-processes10-part2 itself has no
# servlet API dependency (it only supplies TestNG/CTL scripts run inside
# teamengine's webapp), so staying on Tomcat 9 - just with a JRE 17 variant,
# since part2's own classes are compiled for 17 - fixes this without
# affecting part2.
FROM tomcat:9.0.122-jre17-temurin-jammy
ARG BUILD_DEPS=" \
    unzip \
"
COPY --from=build-teamengine /home/app/src/teamengine-web/target/teamengine*.war /root
COPY --from=build-teamengine /home/app/src/teamengine-web/target/teamengine-*common-libs.zip /root
COPY --from=build-teamengine /home/app/src/teamengine-console/target/teamengine-console-*-base.zip /root
COPY --from=build /home/app/src1/ets-ogcapi-processes10-part2/target/ets-ogcapi-processes10part2-*-aio.jar /root
COPY --from=build /home/app/src1/ets-ogcapi-processes10-part2/target/ets-ogcapi-processes10part2-*-ctl.zip /root
COPY --from=build /home/app/src1/ets-ogcapi-processes10-part2/target/ets-ogcapi-processes10part2-*-deps.zip /root
COPY --from=build /home/app/jaxb-libs/*.jar /usr/local/tomcat/lib/
ENV JAVA_OPTS="-Xms1024m -Xmx2048m -DTE_BASE=/root/te_base"
RUN cd /root && \
    mkdir te_base && \
    mkdir te_base/scripts && \
    #echo "deb http://archive.debian.org/debian stretch main" > /etc/apt/sources.list && \
    apt-get update && \
    apt-get install -y $BUILD_DEPS && \
    ls -l && \
    unzip -q -o teamengine*.war -d /usr/local/tomcat/webapps/teamengine && \
    unzip -q -o teamengine-*common-libs.zip -d /usr/local/tomcat/lib && \
    unzip -q -o teamengine-console-*-base.zip -d /root/te_base && \
    unzip -q -o ets-ogcapi-processes10part2-*-ctl.zip -d /root/te_base/scripts && \
    unzip -q -o ets-ogcapi-processes10part2-*-deps.zip -d /usr/local/tomcat/webapps/teamengine/WEB-INF/lib && \
    rm -f *zip *war && \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false $BUILD_DEPS && \
    rm -rf /var/lib/apt/lists/* /root/*zip /root/*war


# run tomcat
CMD ["catalina.sh", "jpda", "run"]
