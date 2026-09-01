FROM apache/nifi:2.11.0

USER root

# Flow's DBCP "Database Driver Locations" references /opt/nifi/lib (legacy path),
# and the top-level DBCP service relies on the driver being on NiFi's classpath
# (NIFI_HOME/lib == /opt/nifi/nifi-current/lib), so place the driver in both.
ADD https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.5/postgresql-42.7.5.jar \
    /opt/nifi/lib/postgresql-42.7.5.jar

ADD https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.5/postgresql-42.7.5.jar \
    /opt/nifi/nifi-current/lib/postgresql-42.7.5.jar

RUN chown nifi:nifi /opt/nifi/lib/postgresql-42.7.5.jar \
                   /opt/nifi/nifi-current/lib/postgresql-42.7.5.jar && \
    chmod 644 /opt/nifi/lib/postgresql-42.7.5.jar \
              /opt/nifi/nifi-current/lib/postgresql-42.7.5.jar

USER nifi