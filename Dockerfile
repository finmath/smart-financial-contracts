# Build Stage: Build fat-jar
FROM maven:3.10.2-eclipse-temurin-17 AS BuildStage
# CVE-2026-114938: protect build JVMs as well as the deployed service.
ENV JAVA_TOOL_OPTIONS="-XX:-UseBASE64Intrinsics"
COPY .git /usr/src/app/.git
COPY src /usr/src/app/src
COPY pom.xml /usr/src/app
RUN mvn -f /usr/src/app/pom.xml clean package spring-boot:repackage -DskipTests \
    && find /usr/src/app/target -maxdepth 1 -type f -name '*.jar' \
       ! -name '*-sources.jar' ! -name '*-javadoc.jar' \
       -exec cp {} /usr/src/app/application.jar \;

# Run Stage: Use a stable filename independent of the Maven release version.
FROM eclipse-temurin:17.0.21.1_2-jre AS RunStage
ENV JAVA_TOOL_OPTIONS="-XX:-UseBASE64Intrinsics"
COPY --from=BuildStage /usr/src/app/application.jar /usr/app/application.jar
ENTRYPOINT ["java", "-jar", "/usr/app/application.jar"]
