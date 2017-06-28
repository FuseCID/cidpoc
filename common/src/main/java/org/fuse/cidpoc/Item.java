package org.fuse.cidpoc;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

public abstract class Item {

    public static class Capability {
        private final String name;
        private final int value;

        public static Capability parse(String spec) {
            String name = spec.substring(0, 1);
            String number = spec.substring(1);
            return new Capability(name, Integer.parseInt(number));
        }
        
        public Capability(String name, int value) {
            this.name = name;
            this.value = value;
        }

        public String getName() {
            return name;
        }

        public int getValue() {
            return value;
        }

        public String toString() {
            return name + value;
        }
    }

    public static class Requirement {
        private final String name;
        private final int min;
        private final int max;

        public static Requirement parse(String spec) {
            String name = spec.substring(0, spec.indexOf('('));
            String min = spec.substring(spec.indexOf('(') + 1, spec.lastIndexOf(')'));
            String max;
            if (min.indexOf('-') > 0) {
                max = min.substring(min.indexOf('-') + 1);
                min = min.substring(0, min.indexOf('-'));
            } else {
                max = min;
            }
            return new Requirement(name, Integer.parseInt(min), Integer.parseInt(max));
        }
        
        public Requirement(String name, int min, int max) {
            this.name = name;
            this.min = min;
            this.max = max;
        }

        public String getName() {
            return name;
        }

        public int getMin() {
            return min;
        }

        public int getMax() {
            return max;
        }

        public boolean matches(Capability cap) {
            return name.equals(cap.getName()) && min <= cap.getValue() && cap.getValue() <= max;
        }

        public String toString() {
            return name + "(" + min + "-" + max + ")";
        }
    }

    public String getVName() {
        return getClass().getSimpleName() + "-" + getVersion(getClass());
    }

    public abstract List<Item> getDependencies();

    public abstract Capability getCapability();

    public List<Requirement> getRequirements() {
        return Collections.emptyList();
    }

    public boolean isSatisfied() {
        boolean result = true;
        for (Item item : getDependencies()) {
            if (!item.isSatisfied()) {
                result = false;
            }
        }
        for (Requirement req : getRequirements()) {
            boolean match = false;
            for (Item item : getDependencies()) {
                if (req.matches(item.getCapability())) {
                    match = true;
                }
            }
            result &= match;
        }
        return result;
    }

    public String getStatus() {
        return (isSatisfied() ? "is " : "is NOT ") + "satisfied";
    }

    public void transitiveStatus() {
        transitiveStatus(new HashSet<>());
    }
    
    public static String getVersion(Class<?> clazz) {
        try (InputStream ins = clazz.getResourceAsStream("version")) {
            return new BufferedReader(new InputStreamReader(ins)).readLine();
        } catch (IOException ex) {
            throw new IllegalStateException(ex);
        }
    }
    
    private void transitiveStatus(Set<String> visited) {
        if (!visited.contains(getVName())) {
            for (Item item : getDependencies()) {
                item.transitiveStatus(visited);
            }
            System.out.println(getVName());
            System.out.println("Dependencies: " + getDependencies());
            System.out.println("Provides: " + getCapability());
            System.out.println("Requires: " + getRequirements());
            System.out.println(getStatus());
            System.out.println();
            visited.add(getVName());
        }
    }
    
    public String toString() {
        return getVName();
    }
}
