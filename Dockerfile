# Build Stage: Build fat-jar
FROM maven:3.8.1-openjdk-17 AS buildstage
COPY .git /usr/src/app/.git
COPY src /usr/src/app/src
COPY pom.xml /usr/src/app
RUN mvn -f /usr/src/app/pom.xml clean package spring-boot:repackage -DskipTests \
    && find /usr/src/app/target -maxdepth 1 -type f -name '*.jar' \
       ! -name '*-sources.jar' ! -name '*-javadoc.jar' \
       -exec cp {} /usr/src/app/application.jar \;

# Run Stage: Use a stable filename independent of the Maven release version.
FROM eclipse-temurin:17-jdk AS runstage
COPY --from=buildstage /usr/src/app/application.jar /usr/app/application.jar
ENTRYPOINT ["java", "-jar", "/usr/app/application.jar"]
