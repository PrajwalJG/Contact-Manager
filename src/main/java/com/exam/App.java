package com.exam;

import com.exam.model.Contact;
import com.exam.service.ContactService;

public class App {
    public static void main(String[] args) {
        ContactService service = new ContactService();
        service.addContact(new Contact("Charlie", "123-456-7890"));
        service.addContact(new Contact("Bob", "987-654-3210"));

        System.out.println("--- Contact Manager ---");
        System.out.println("Total: " + service.getContactCount());
        service.getAllContacts().forEach(System.out::println);
    }
}
