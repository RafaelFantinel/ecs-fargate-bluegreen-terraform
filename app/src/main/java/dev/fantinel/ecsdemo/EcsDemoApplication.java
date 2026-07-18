package dev.fantinel.ecsdemo;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@SpringBootApplication
@RestController
public class EcsDemoApplication {

    // Injected at deploy time so blue/green switchover is visible in responses.
    @Value("${APP_VERSION:local}")
    private String appVersion;

    public static void main(String[] args) {
        SpringApplication.run(EcsDemoApplication.class, args);
    }

    @GetMapping("/")
    public Map<String, String> index() {
        return Map.of(
                "service", "ecs-demo-app",
                "version", appVersion,
                "message", "Deployed via blue/green on ECS"
        );
    }
}
